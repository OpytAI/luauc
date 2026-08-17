import { execFileSync } from "node:child_process";

export function oracleLines(interpreter, modules, inputs) {
  const stdout = execFileSync(interpreter, modules, { encoding: "utf8" });
  const lines = stdout.trim().split("\n").filter((line) => line.startsWith("result="));
  return inputs.map(([number, text]) => {
    const prefix = `result=${number}|${text}|`;
    const line = lines.find((entry) => entry.startsWith(prefix));
    if (!line) throw new Error(`oracle missing ${number}/${text} in ${JSON.stringify(lines)}`);
    const rest = line.slice("result=".length).split("|");
    return { number: Number(rest[2]), text: rest.slice(3).join("|") };
  });
}
