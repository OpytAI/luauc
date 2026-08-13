use anyhow::{anyhow, bail, Context, Result};
use sha2::{Digest, Sha256};
use std::{env, fs};
use wasmtime::{Caller, Engine, Extern, Instance, Linker, Memory, Module, Store};

const SOURCE_HEADER_SIZE: usize = 160;
const SOURCE_RECORD_SIZE: usize = 64;

#[derive(Clone)]
struct SourceModule {
    name: Vec<u8>,
    source_name: Vec<u8>,
    source: Vec<u8>,
}

fn digest(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

fn put_u16(bytes: &mut [u8], offset: usize, value: u16) {
    bytes[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
}

fn put_u32(bytes: &mut [u8], offset: usize, value: u32) {
    bytes[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
}

fn put_i64(bytes: &mut [u8], offset: usize, value: i64) {
    bytes[offset..offset + 8].copy_from_slice(&value.to_le_bytes());
}

fn get_u32(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap())
}

fn get_i64(bytes: &[u8], offset: usize) -> i64 {
    i64::from_le_bytes(bytes[offset..offset + 8].try_into().unwrap())
}

fn append_sized(target: &mut Vec<u8>, value: &[u8]) {
    target.extend_from_slice(&(value.len() as u32).to_le_bytes());
    target.extend_from_slice(value);
}

fn source_request(
    mut modules: Vec<SourceModule>,
    entry_name: &[u8],
    profile_digest: &[u8; 32],
    pack_digest: &[u8; 32],
) -> Result<Vec<u8>> {
    modules.sort_by(|lhs, rhs| lhs.name.cmp(&rhs.name));
    if modules.is_empty() || modules.windows(2).any(|pair| pair[0].name == pair[1].name) {
        bail!("source package has no modules or duplicate names");
    }
    let entry_id = modules
        .iter()
        .position(|module| module.name == entry_name)
        .ok_or_else(|| anyhow!("entry module is absent"))?;

    let mut manifest = Vec::new();
    manifest.extend_from_slice(&(modules.len() as u32).to_le_bytes());
    manifest.extend_from_slice(&(entry_id as u32).to_le_bytes());
    let mut content_digests = Vec::with_capacity(modules.len());
    for module in &modules {
        let content_digest = digest(&module.source);
        append_sized(&mut manifest, &module.name);
        append_sized(&mut manifest, &module.source_name);
        manifest.extend_from_slice(&content_digest);
        content_digests.push(content_digest);
    }
    let manifest_digest = digest(&manifest);
    let total = SOURCE_HEADER_SIZE
        + SOURCE_RECORD_SIZE * modules.len()
        + modules
            .iter()
            .map(|module| module.name.len() + module.source_name.len() + module.source.len())
            .sum::<usize>();
    let mut request = vec![0; total];
    request[0..8].copy_from_slice(b"LUAUCS1\0");
    put_u16(&mut request, 8, 1);
    put_u16(&mut request, 10, SOURCE_HEADER_SIZE as u16);
    put_u32(&mut request, 12, total.try_into()?);
    put_u32(&mut request, 16, modules.len().try_into()?);
    put_u32(&mut request, 20, entry_id.try_into()?);
    put_u32(&mut request, 24, SOURCE_RECORD_SIZE as u32);
    let mut request_identity = Sha256::new();
    request_identity.update(b"luauc-source-request-v1\0");
    request_identity.update(profile_digest);
    request_identity.update(pack_digest);
    request_identity.update(manifest_digest);
    request[32..48].copy_from_slice(&request_identity.finalize()[..16]);
    request[48..80].copy_from_slice(profile_digest);
    request[80..112].copy_from_slice(pack_digest);
    request[112..144].copy_from_slice(&manifest_digest);

    let mut cursor = SOURCE_HEADER_SIZE + SOURCE_RECORD_SIZE * modules.len();
    for (index, module) in modules.iter().enumerate() {
        let record = SOURCE_HEADER_SIZE + SOURCE_RECORD_SIZE * index;
        put_u32(&mut request, record, cursor.try_into()?);
        put_u32(&mut request, record + 4, module.name.len().try_into()?);
        request[cursor..cursor + module.name.len()].copy_from_slice(&module.name);
        cursor += module.name.len();
        put_u32(&mut request, record + 8, cursor.try_into()?);
        put_u32(
            &mut request,
            record + 12,
            module.source_name.len().try_into()?,
        );
        request[cursor..cursor + module.source_name.len()].copy_from_slice(&module.source_name);
        cursor += module.source_name.len();
        put_u32(&mut request, record + 16, cursor.try_into()?);
        put_u32(&mut request, record + 20, module.source.len().try_into()?);
        request[cursor..cursor + module.source.len()].copy_from_slice(&module.source);
        cursor += module.source.len();
        request[record + 24..record + 56].copy_from_slice(&content_digests[index]);
    }
    if cursor != request.len() {
        bail!("source package layout drifted");
    }
    Ok(request)
}

fn compiler_alloc(
    store: &mut Store<()>,
    memory: Memory,
    alloc: &wasmtime::TypedFunc<u32, u32>,
    bytes: &[u8],
) -> Result<u32> {
    let pointer = alloc.call(&mut *store, bytes.len().try_into()?)?;
    if pointer == 0 {
        bail!("compiler allocation failed");
    }
    memory.write(&mut *store, pointer as usize, bytes)?;
    Ok(pointer)
}

fn compile_package(
    engine: &Engine,
    compiler_module: &Module,
    profile: &[u8],
    pack: &[u8],
    modules: Vec<SourceModule>,
) -> Result<Vec<u8>> {
    let mut store = Store::new(engine, ());
    let instance = Instance::new(&mut store, compiler_module, &[])?;
    let memory = instance
        .get_memory(&mut store, "memory")
        .ok_or_else(|| anyhow!("compiler has no memory export"))?;
    let alloc = instance.get_typed_func::<u32, u32>(&mut store, "luauc_v1_alloc")?;
    let dealloc = instance.get_typed_func::<(u32, u32), ()>(&mut store, "luauc_v1_dealloc")?;
    let context_create = instance
        .get_typed_func::<(u32, u32, u32, u32, u32), u32>(&mut store, "luauc_v1_context_create")?;
    let context_destroy =
        instance.get_typed_func::<u32, u32>(&mut store, "luauc_v1_context_destroy")?;
    let compile =
        instance.get_typed_func::<(u32, u32, u32, u32), u32>(&mut store, "luauc_v1_compile")?;
    let result_free = instance.get_typed_func::<u32, ()>(&mut store, "luauc_v1_result_free")?;

    let profile_pointer = compiler_alloc(&mut store, memory, &alloc, profile)?;
    let pack_pointer = compiler_alloc(&mut store, memory, &alloc, pack)?;
    let context_result = compiler_alloc(&mut store, memory, &alloc, &[0; 72])?;
    let create_status = context_create.call(
        &mut store,
        (
            profile_pointer,
            profile.len().try_into()?,
            pack_pointer,
            pack.len().try_into()?,
            context_result,
        ),
    )?;
    let mut context_bytes = [0; 72];
    memory.read(&store, context_result as usize, &mut context_bytes)?;
    if create_status != 0 || get_u32(&context_bytes, 4) != 0 {
        bail!(
            "compiler context creation failed: {create_status}/{}",
            get_u32(&context_bytes, 4)
        );
    }
    let handle = get_u32(&context_bytes, 0);
    let profile_digest: [u8; 32] = context_bytes[8..40].try_into().unwrap();
    let pack_digest: [u8; 32] = context_bytes[40..72].try_into().unwrap();
    let request = source_request(modules, b"main", &profile_digest, &pack_digest)?;
    let request_pointer = compiler_alloc(&mut store, memory, &alloc, &request)?;
    let compile_result = compiler_alloc(&mut store, memory, &alloc, &[0; 208])?;

    let outcome = (|| -> Result<Vec<u8>> {
        let status = compile.call(
            &mut store,
            (
                handle,
                request_pointer,
                request.len().try_into()?,
                compile_result,
            ),
        )?;
        let mut result = [0; 208];
        memory.read(&store, compile_result as usize, &mut result)?;
        if status != 0 || get_u32(&result, 16) != 0 {
            let diagnostic_pointer = get_u32(&result, 8);
            let diagnostic_size = get_u32(&result, 12);
            let mut diagnostic = vec![0; diagnostic_size as usize];
            if diagnostic_pointer != 0 && diagnostic_size != 0 {
                memory.read(&store, diagnostic_pointer as usize, &mut diagnostic)?;
            }
            bail!(
                "compiler failed: {status}/{}: {}",
                get_u32(&result, 16),
                String::from_utf8_lossy(&diagnostic)
            );
        }
        let pointer = get_u32(&result, 0);
        let size = get_u32(&result, 4);
        let mut artifact = vec![0; size as usize];
        memory.read(&store, pointer as usize, &mut artifact)?;
        if result[40..72] != profile_digest
            || result[72..104] != pack_digest
            || result[168..200] != digest(&artifact)
        {
            bail!("compiler result provenance does not bind the artifact");
        }
        Ok(artifact)
    })();

    result_free.call(&mut store, compile_result)?;
    dealloc.call(&mut store, (compile_result, 208))?;
    dealloc.call(&mut store, (request_pointer, request.len().try_into()?))?;
    if context_destroy.call(&mut store, handle)? != 0 {
        bail!("compiler context destroy failed");
    }
    dealloc.call(&mut store, (context_result, 72))?;
    dealloc.call(&mut store, (pack_pointer, pack.len().try_into()?))?;
    dealloc.call(&mut store, (profile_pointer, profile.len().try_into()?))?;
    outcome
}

#[derive(Default)]
struct RuntimeState {
    throw_codes: Vec<u32>,
}

fn runtime_instance(
    engine: &Engine,
    artifact: &[u8],
) -> Result<(Store<RuntimeState>, Instance, Memory)> {
    let module = Module::from_binary(engine, artifact)?;
    let mut linker = Linker::new(engine);
    linker.func_wrap(
        "luauc_embed_v1",
        "set_throw",
        |mut caller: Caller<'_, RuntimeState>, code: i32| {
            caller.data_mut().throw_codes.push(code as u32);
        },
    )?;
    linker.func_wrap(
        "luauc_embed_v1",
        "protected_call",
        |mut caller: Caller<'_, RuntimeState>| -> std::result::Result<i32, wasmtime::Error> {
            let dispatch = caller
                .get_export("luauc_embed_v1_protected_call_run")
                .and_then(Extern::into_func)
                .ok_or_else(|| {
                    wasmtime::Error::msg("runtime profile has no protected dispatcher")
                })?;
            let dispatch = dispatch.typed::<(), ()>(&caller)?;
            match dispatch.call(&mut caller, ()) {
                Ok(()) => Ok(0),
                Err(error) => match caller.data_mut().throw_codes.pop() {
                    Some(code) => Ok(code as i32),
                    None => Err(error),
                },
            }
        },
    )?;
    let mut store = Store::new(engine, RuntimeState::default());
    let instance = linker.instantiate(&mut store, &module)?;
    let memory = instance
        .get_memory(&mut store, "memory")
        .ok_or_else(|| anyhow!("runtime profile has no memory"))?;
    instance
        .get_typed_func::<(), ()>(&mut store, "_start")?
        .call(&mut store, ())?;
    if !store.data().throw_codes.is_empty() {
        bail!("runtime initializer retained protected throw state");
    }
    Ok((store, instance, memory))
}

fn invoke(
    store: &mut Store<RuntimeState>,
    instance: &Instance,
    memory: Memory,
    number: i64,
    text: &str,
) -> Result<(i64, String)> {
    let alloc = instance.get_typed_func::<u32, u32>(&mut *store, "luauc_embed_v1_alloc")?;
    let dealloc = instance.get_typed_func::<u32, ()>(&mut *store, "luauc_embed_v1_dealloc")?;
    let context_create =
        instance.get_typed_func::<(), u32>(&mut *store, "luauc_embed_v1_context_create")?;
    let context_destroy =
        instance.get_typed_func::<u32, ()>(&mut *store, "luauc_embed_v1_context_destroy")?;
    let invoke = instance
        .get_typed_func::<(u32, u32, u32, u32), u32>(&mut *store, "luauc_embed_v1_invoke")?;
    let text_pointer = alloc.call(&mut *store, text.len().try_into()?)?;
    let output_pointer = alloc.call(&mut *store, 4096)?;
    let request_pointer = alloc.call(&mut *store, 32)?;
    let result_pointer = alloc.call(&mut *store, 32)?;
    let context = context_create.call(&mut *store, ())?;
    if text_pointer == 0
        || output_pointer == 0
        || request_pointer == 0
        || result_pointer == 0
        || context == 0
    {
        bail!("runtime allocation or context creation failed");
    }
    memory.write(&mut *store, text_pointer as usize, text.as_bytes())?;
    let mut request = [0; 32];
    put_u32(&mut request, 0, 1);
    put_u32(&mut request, 4, 32);
    put_i64(&mut request, 8, number);
    put_u32(&mut request, 16, text_pointer);
    put_u32(&mut request, 20, text.len().try_into()?);
    put_u32(&mut request, 24, output_pointer);
    put_u32(&mut request, 28, 4096);
    memory.write(&mut *store, request_pointer as usize, &request)?;
    memory.write(&mut *store, result_pointer as usize, &[0; 32])?;
    let status = invoke.call(&mut *store, (context, request_pointer, 32, result_pointer))?;
    let mut result = [0; 32];
    memory.read(&*store, result_pointer as usize, &mut result)?;
    let output_size = get_u32(&result, 16);
    let mut output = vec![0; output_size as usize];
    memory.read(&*store, output_pointer as usize, &mut output)?;
    context_destroy.call(&mut *store, context)?;
    for pointer in [
        result_pointer,
        request_pointer,
        output_pointer,
        text_pointer,
    ] {
        dealloc.call(&mut *store, pointer)?;
    }
    if status != 0 || get_u32(&result, 0) != 0 || get_u32(&result, 4) & 1 != 0 {
        bail!(
            "runtime invocation failed: {status}/{}: {}",
            get_u32(&result, 0),
            String::from_utf8_lossy(&output)
        );
    }
    Ok((get_i64(&result, 8), String::from_utf8(output)?))
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut result = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        result.push(DIGITS[(byte >> 4) as usize] as char);
        result.push(DIGITS[(byte & 15) as usize] as char);
    }
    result
}

fn run_inputs(engine: &Engine, artifact: &[u8], arguments: &[String]) -> Result<()> {
    if arguments.is_empty() || arguments.len() % 2 != 0 {
        bail!("runtime inputs must be <number> <text> pairs");
    }
    let (mut store, instance, memory) = runtime_instance(engine, artifact)?;
    for pair in arguments.chunks_exact(2) {
        let input = pair[0].parse::<i64>().context("parse input number")?;
        let label = pair[1].as_str();
        let (number, text) = invoke(&mut store, &instance, memory, input, label)?;
        println!("result={input}|{label}|{number}|{text}");
    }
    Ok(())
}

fn compile_run(arguments: &[String]) -> Result<()> {
    if arguments.len() < 7 || (arguments.len() - 5) % 2 != 0 {
        bail!("usage: luauc-embed-wasmtime compile-run <compiler.wasm> <profile> <pack.wasm> <lib.luau> <main.luau> <number> <text> [<number> <text> ...]");
    }
    let compiler = fs::read(&arguments[0]).context("read compiler")?;
    let profile = fs::read(&arguments[1]).context("read profile")?;
    let pack = fs::read(&arguments[2]).context("read pack")?;
    let modules = vec![
        SourceModule {
            name: b"lib".to_vec(),
            source_name: b"@lib.luau".to_vec(),
            source: fs::read(&arguments[3]).context("read lib source")?,
        },
        SourceModule {
            name: b"main".to_vec(),
            source_name: b"@main.luau".to_vec(),
            source: fs::read(&arguments[4]).context("read main source")?,
        },
    ];
    let engine = Engine::default();
    let compiler_module = Module::from_binary(&engine, &compiler)?;
    if compiler_module.imports().next().is_some() {
        bail!("luauc compiler has imports");
    }
    let artifact = compile_package(&engine, &compiler_module, &profile, &pack, modules.clone())?;
    let repeated = compile_package(&engine, &compiler_module, &profile, &pack, modules)?;
    if artifact != repeated {
        bail!("Wasmtime compiler output is nondeterministic");
    }
    println!("artifact={}", hex(&digest(&artifact)));
    run_inputs(&engine, &artifact, &arguments[5..])
}

fn main() -> Result<()> {
    let arguments: Vec<String> = env::args().skip(1).collect();
    match arguments.first().map(String::as_str) {
        Some("compile-run") => compile_run(&arguments[1..]),
        Some("run") if arguments.len() >= 4 => {
            let engine = Engine::default();
            let artifact = fs::read(&arguments[1]).context("read artifact")?;
            run_inputs(&engine, &artifact, &arguments[2..])
        }
        _ => bail!("usage: luauc-embed-wasmtime compile-run <compiler.wasm> <profile> <pack.wasm> <lib.luau> <main.luau> <number> <text>... | run <artifact.wasm> <number> <text>..."),
    }
}
