#pragma once

#include "Luau/Allocator.h"
#include "Luau/Ast.h"
#include "Luau/Parser.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

struct LuaucLivenessSource
{
    const char* name;
    size_t nameSize;
    const char* source;
    size_t sourceSize;
    char* rewritten;
};

namespace LuaucLiveness
{
using namespace Luau;

struct Value
{
    bool unknown = false;
    std::vector<size_t> objects;
};

struct Object
{
    AstExprFunction* function = nullptr;
    AstStat* declaration = nullptr;
    size_t module = 0;
    bool active = false;
    bool observed = false;
    bool escaped = false;
    std::unordered_map<std::string, Value> fields;
    std::unordered_set<std::string> reads;
    Value unknownFields;
    Value returns;
    Value varargs;
};

struct Module
{
    Allocator allocator;
    AstNameTable names{allocator};
    ParseResult parsed;
    Value returns;
    bool hasGoto = false;
};

class Analysis
{
    std::vector<std::unique_ptr<Module>> modules;
    std::vector<std::unique_ptr<Object>> objects;
    std::unordered_map<AstExpr*, size_t> identities;
    std::unordered_map<AstLocal*, Value> locals;
    std::unordered_map<AstLocal*, AstExpr*> initializers;
    std::unordered_set<AstLocal*> assigned;
    std::unordered_map<std::string, size_t> moduleNames;
    bool changed = false;
    bool disabled = false;
    size_t currentModule = 0;
    Object* currentFunction = nullptr;
    size_t operations = 0;

    static bool unite(Value& target, const Value& source)
    {
        bool changed = false;
        if (source.unknown && !target.unknown)
            changed = target.unknown = true;
        for (size_t identity : source.objects)
            if (std::find(target.objects.begin(), target.objects.end(), identity) == target.objects.end())
            {
                target.objects.push_back(identity);
                changed = true;
            }
        return changed;
    }

    void merge(Value& target, const Value& source)
    {
        changed |= unite(target, source);
    }

    Value identity(AstExpr* expression)
    {
        return {false, {identities.at(expression)}};
    }

    void observe(const Value& value)
    {
        for (size_t identity : value.objects)
            if (!objects[identity]->observed)
                changed = objects[identity]->observed = true;
    }

    void escape(const Value& value)
    {
        for (size_t identity : value.objects)
            if (!objects[identity]->escaped)
                changed = objects[identity]->escaped = true;
    }

    Value field(const Value& base, const std::string& key)
    {
        Value result{base.unknown, {}};
        for (size_t identity : base.objects)
        {
            Object& object = *objects[identity];
            result.unknown |= object.escaped;
            object.reads.insert(key);
            if (object.function)
                result.unknown = true;
            else
            {
                unite(result, object.fields[key]);
                unite(result, object.unknownFields);
            }
        }
        observe(result);
        return result;
    }

    void store(const Value& base, const std::string& key, const Value& value)
    {
        if (base.unknown)
            escape(value);
        for (size_t identity : base.objects)
        {
            Object& object = *objects[identity];
            if (object.function)
                escape(value);
            else
                merge(object.fields[key], value);
        }
    }

    static std::string string(AstExprConstantString* expression)
    {
        return {expression->value.data, expression->value.size};
    }

    void storeUnknown(const Value& base, const Value& value)
    {
        if (base.unknown)
            escape(value);
        for (size_t identity : base.objects)
        {
            Object& object = *objects[identity];
            if (object.function)
                escape(value);
            else
                merge(object.unknownFields, value);
        }
    }

    void assign(AstExpr* target, const Value& value)
    {
        if (auto* local = target->as<AstExprLocal>())
            merge(locals[local->local], value);
        else if (auto* named = target->as<AstExprIndexName>())
            store(eval(named->expr), named->index.value, value);
        else if (auto* indexed = target->as<AstExprIndexExpr>())
        {
            Value base = eval(indexed->expr);
            if (auto* key = indexed->index->as<AstExprConstantString>())
                store(base, string(key), value);
            else
            {
                escape(eval(indexed->index));
                storeUnknown(base, value);
            }
        }
        else
        {
            disabled = true;
            escape(value);
        }
    }

    Value call(AstExprCall* expression)
    {
        if (auto* global = expression->func->as<AstExprGlobal>())
        {
            if (global->name == "require")
            {
                if (expression->args.size != 1 || !expression->args.data[0]->is<AstExprConstantString>())
                {
                    disabled = true;
                    return {true, {}};
                }
                auto found = moduleNames.find(string(expression->args.data[0]->as<AstExprConstantString>()));
                return found == moduleNames.end() ? Value{true, {}} : modules[found->second]->returns;
            }
            if (global->name == "getfenv" || global->name == "setfenv" || global->name == "loadstring")
                disabled = true;
        }
        Value function = eval(expression->func);
        std::vector<Value> args;
        if (expression->self)
        {
            auto* index = expression->func->as<AstExprIndexName>();
            if (!index)
            {
                disabled = true;
                return {true, {}};
            }
            args.push_back(eval(index->expr));
        }
        for (AstExpr* argument : expression->args)
            args.push_back(eval(argument));
        const bool multiple = expression->args.size &&
            (expression->args.data[expression->args.size - 1]->is<AstExprCall>() ||
                expression->args.data[expression->args.size - 1]->is<AstExprVarargs>());
        Value result;
        if (function.unknown)
        {
            for (const Value& argument : args)
                escape(argument);
            result.unknown = true;
        }
        for (size_t identity : function.objects)
        {
            Object& object = *objects[identity];
            if (!object.function)
            {
                escape({false, {identity}});
                for (const Value& argument : args)
                    escape(argument);
                result.unknown = true;
                continue;
            }
            if (!object.active)
                changed = object.active = true;
            size_t index = 0;
            if (object.function->self)
            {
                if (index < args.size())
                    merge(locals[object.function->self], args[index]);
                ++index;
            }
            for (AstLocal* parameter : object.function->args)
            {
                if (index < args.size())
                    merge(locals[parameter], args[index]);
                else if (multiple)
                    merge(locals[parameter], args.back());
                ++index;
            }
            if (object.function->vararg)
            {
                for (; index < args.size(); ++index)
                    merge(object.varargs, args[index]);
                if (multiple)
                    merge(object.varargs, args.back());
            }
            unite(result, object.returns);
        }
        return result;
    }

    Value eval(AstExpr* expression)
    {
        if (!expression || disabled || ++operations > 20000000)
        {
            disabled = true;
            return {true, {}};
        }
        if (auto* local = expression->as<AstExprLocal>())
            return locals[local->local];
        if (auto* global = expression->as<AstExprGlobal>())
        {
            if (global->name == "require" || global->name == "getfenv" || global->name == "setfenv" || global->name == "loadstring")
                disabled = true;
            return {true, {}};
        }
        if (expression->is<AstExprFunction>())
            return identity(expression);
        if (auto* table = expression->as<AstExprTable>())
        {
            Value result = identity(expression);
            for (const auto& item : table->items)
            {
                Value value = eval(item.value);
                if (item.key && item.key->is<AstExprConstantString>())
                    store(result, string(item.key->as<AstExprConstantString>()), value);
                else
                {
                    if (item.key)
                        escape(eval(item.key));
                    storeUnknown(result, value);
                }
            }
            return result;
        }
        if (auto* named = expression->as<AstExprIndexName>())
            return field(eval(named->expr), named->index.value);
        if (auto* indexed = expression->as<AstExprIndexExpr>())
        {
            Value base = eval(indexed->expr);
            if (auto* key = indexed->index->as<AstExprConstantString>())
                return field(base, string(key));
            escape(base);
            escape(eval(indexed->index));
            Value result{true, {}};
            for (size_t identity : base.objects)
            {
                for (const auto& entry : objects[identity]->fields)
                    unite(result, entry.second);
                unite(result, objects[identity]->unknownFields);
            }
            return result;
        }
        if (auto* invocation = expression->as<AstExprCall>())
            return call(invocation);
        if (auto* group = expression->as<AstExprGroup>())
            return eval(group->expr);
        if (auto* assertion = expression->as<AstExprTypeAssertion>())
            return eval(assertion->expr);
        if (auto* instantiate = expression->as<AstExprInstantiate>())
            return eval(instantiate->expr);
        if (auto* binary = expression->as<AstExprBinary>())
        {
            Value left = eval(binary->left);
            Value right = eval(binary->right);
            if (binary->op == AstExprBinary::And || binary->op == AstExprBinary::Or)
            {
                unite(left, right);
                return left;
            }
            observe(left);
            observe(right);
            return {true, {}};
        }
        if (auto* unary = expression->as<AstExprUnary>())
        {
            Value value = eval(unary->expr);
            if (unary->op == AstExprUnary::Op::Len)
                escape(value);
            else
                observe(value);
            return {true, {}};
        }
        if (auto* conditional = expression->as<AstExprIfElse>())
        {
            observe(eval(conditional->condition));
            Value result = eval(conditional->trueExpr);
            unite(result, eval(conditional->falseExpr));
            return result;
        }
        if (auto* interpolated = expression->as<AstExprInterpString>())
        {
            for (AstExpr* value : interpolated->expressions)
                escape(eval(value));
            return {};
        }
        if (expression->is<AstExprVarargs>())
            return currentFunction ? currentFunction->varargs : Value{true, {}};
        if (expression->is<AstExprConstantNil>() || expression->is<AstExprConstantBool>() ||
            expression->is<AstExprConstantNumber>() || expression->is<AstExprConstantInteger>() ||
            expression->is<AstExprConstantString>())
            return {};
        disabled = true;
        return {true, {}};
    }

    void statement(AstStat* node)
    {
        if (disabled || ++operations > 20000000)
        {
            disabled = true;
            return;
        }
        if (auto* block = node->as<AstStatBlock>())
            for (AstStat* child : block->body)
                statement(child);
        else if (auto* local = node->as<AstStatLocal>())
        {
            std::vector<Value> values;
            for (AstExpr* expression : local->values)
                values.push_back(eval(expression));
            for (size_t index = 0; index < local->vars.size; ++index)
            {
                Value value = index < values.size() ? values[index] :
                    (!values.empty() && (local->values.data[values.size() - 1]->is<AstExprCall>() ||
                        local->values.data[values.size() - 1]->is<AstExprVarargs>()) ? values.back() : Value{});
                merge(locals[local->vars.data[index]], value);
                if (local->vars.data[index]->isExported)
                    escape(value);
            }
        }
        else if (auto* local = node->as<AstStatLocalFunction>())
            merge(locals[local->name], identity(local->func));
        else if (auto* function = node->as<AstStatFunction>())
            assign(function->name, identity(function->func));
        else if (auto* assignment = node->as<AstStatAssign>())
        {
            std::vector<Value> values;
            for (AstExpr* expression : assignment->values)
                values.push_back(eval(expression));
            for (size_t index = 0; index < assignment->vars.size; ++index)
                assign(assignment->vars.data[index], index < values.size() ? values[index] :
                    (!values.empty() && (assignment->values.data[values.size() - 1]->is<AstExprCall>() ||
                        assignment->values.data[values.size() - 1]->is<AstExprVarargs>()) ? values.back() : Value{}));
        }
        else if (auto* assignment = node->as<AstStatCompoundAssign>())
        {
            observe(eval(assignment->var));
            observe(eval(assignment->value));
            assign(assignment->var, {true, {}});
        }
        else if (auto* returned = node->as<AstStatReturn>())
            for (AstExpr* expression : returned->list)
                merge(currentFunction ? currentFunction->returns : modules[currentModule]->returns, eval(expression));
        else if (auto* expression = node->as<AstStatExpr>())
            observe(eval(expression->expr));
        else if (auto* conditional = node->as<AstStatIf>())
        {
            observe(eval(conditional->condition));
            statement(conditional->thenbody);
            if (conditional->elsebody)
                statement(conditional->elsebody);
        }
        else if (auto* loop = node->as<AstStatWhile>())
        {
            observe(eval(loop->condition));
            statement(loop->body);
        }
        else if (auto* loop = node->as<AstStatRepeat>())
        {
            statement(loop->body);
            observe(eval(loop->condition));
        }
        else if (auto* loop = node->as<AstStatFor>())
        {
            observe(eval(loop->from));
            observe(eval(loop->to));
            if (loop->step)
                observe(eval(loop->step));
            statement(loop->body);
        }
        else if (auto* loop = node->as<AstStatForIn>())
        {
            for (AstExpr* value : loop->values)
                escape(eval(value));
            for (AstLocal* local : loop->vars)
                merge(locals[local], {true, {}});
            statement(loop->body);
        }
        else if (!node->is<AstStatBreak>() && !node->is<AstStatContinue>() &&
            !node->is<AstStatLabel>() && !node->is<AstStatGoto>() &&
            !node->is<AstStatTypeAlias>() && !node->is<AstStatTypeFunction>())
            disabled = true;
    }

    struct Collector : AstVisitor
    {
        Analysis& analysis;
        size_t module;
        Collector(Analysis& analysis, size_t module) : analysis(analysis), module(module) {}

        void add(AstExpr* node, AstExprFunction* function)
        {
            if (analysis.identities.count(node))
                return;
            analysis.identities[node] = analysis.objects.size();
            auto object = std::make_unique<Object>();
            object->function = function;
            object->module = module;
            analysis.objects.push_back(std::move(object));
        }

        bool visit(AstExprTable* node) override
        {
            add(node, nullptr);
            return true;
        }

        bool visit(AstExprFunction* node) override
        {
            add(node, node);
            analysis.disabled |= node->hasNativeAttribute();
            return true;
        }

        bool visit(AstStatFunction* node) override
        {
            if (auto* local = node->name->as<AstExprLocal>())
                analysis.assigned.insert(local->local);
            add(node->func, node->func);
            analysis.objects[analysis.identities.at(node->func)]->declaration = node;
            return true;
        }

        bool visit(AstStatLocalFunction* node) override
        {
            add(node->func, node->func);
            analysis.objects[analysis.identities.at(node->func)]->declaration = node;
            return true;
        }

        bool visit(AstStatLocal* node) override
        {
            for (size_t index = 0; index < node->vars.size && index < node->values.size; ++index)
                analysis.initializers[node->vars.data[index]] = node->values.data[index];
            return true;
        }

        bool visit(AstStatAssign* node) override
        {
            for (AstExpr* target : node->vars)
                if (auto* local = target->as<AstExprLocal>())
                    analysis.assigned.insert(local->local);
            return true;
        }

        bool visit(AstStatCompoundAssign* node) override
        {
            if (auto* local = node->var->as<AstExprLocal>())
                analysis.assigned.insert(local->local);
            return true;
        }

        bool visit(AstStatGoto*) override
        {
            analysis.modules[module]->hasGoto = true;
            return false;
        }

        bool visit(AstExprGlobal* node) override
        {
            analysis.disabled |= node->name == "getfenv" || node->name == "setfenv" ||
                node->name == "loadstring" || node->name == "_G";
            return false;
        }

        bool visit(AstStatTypeFunction*) override
        {
            return false;
        }
    };

    static size_t offset(const LuaucLivenessSource& source, Position position)
    {
        size_t cursor = 0;
        for (unsigned line = 0; line < position.line && cursor < source.sourceSize;)
            if (source.source[cursor++] == '\n')
                ++line;
        return std::min(source.sourceSize, cursor + position.column);
    }

public:
    void run(LuaucLivenessSource* sources, size_t count, size_t entry)
    {
        if (count == 0 || entry >= count)
            return;
        size_t totalSize = 0;
        for (size_t index = 0; index < count; ++index)
        {
            if (sources[index].sourceSize > 8 * 1024 * 1024 - totalSize)
                return;
            totalSize += sources[index].sourceSize;
        }
        for (size_t index = 0; index < count; ++index)
        {
            auto module = std::make_unique<Module>();
            module->parsed = Parser::parse(sources[index].source, sources[index].sourceSize, module->names, module->allocator);
            if (!module->parsed.errors.empty() || !module->parsed.root)
                return;
            moduleNames.emplace(std::string(sources[index].name, sources[index].nameSize), index);
            modules.push_back(std::move(module));
            Collector collector(*this, index);
            modules.back()->parsed.root->visit(&collector);
        }
        for (size_t iteration = 0; iteration < 256; ++iteration)
        {
            changed = false;
            currentFunction = nullptr;
            for (currentModule = 0; currentModule < count; ++currentModule)
                statement(modules[currentModule]->parsed.root);
            escape(modules[entry]->returns);
            for (auto& owned : objects)
            {
                Object& object = *owned;
                if (object.escaped)
                {
                    if (object.function)
                    {
                        if (!object.active)
                            changed = object.active = true;
                        if (object.function->self)
                            merge(locals[object.function->self], {true, {}});
                        for (AstLocal* parameter : object.function->args)
                            merge(locals[parameter], {true, {}});
                        merge(object.varargs, {true, {}});
                        escape(object.returns);
                    }
                    else
                    {
                        for (const auto& field : object.fields)
                            escape(field.second);
                        escape(object.unknownFields);
                    }
                }
                if (object.active)
                {
                    currentFunction = &object;
                    currentModule = object.module;
                    statement(object.function->body);
                }
            }
            if (disabled)
                return;
            if (changed)
                continue;
            rewrite(sources, count);
            return;
        }
    }

    bool removableField(AstExpr* expression, size_t module)
    {
        if (modules[module]->hasGoto)
            return false;
        auto* field = expression->as<AstExprIndexName>();
        if (!field)
            return false;
        AstExpr* base = field->expr;
        for (size_t depth = 0; depth <= initializers.size(); ++depth)
        {
            if (auto* table = base->as<AstExprTable>())
            {
                const Object& object = *objects[identities.at(table)];
                return !object.escaped && !object.reads.count(field->index.value);
            }
            auto* local = base->as<AstExprLocal>();
            if (!local || assigned.count(local->local))
                return false;
            auto found = initializers.find(local->local);
            if (found == initializers.end())
                return false;
            base = found->second;
        }
        return false;
    }

    void rewrite(LuaucLivenessSource* sources, size_t count)
    {
        struct Edit { size_t start; size_t end; std::string text; };
        std::vector<std::vector<Edit>> edits(count);
        for (const auto& owned : objects)
        {
            const Object& object = *owned;
            if (!object.function || object.active || object.observed || object.escaped)
                continue;
            const auto& source = sources[object.module];
            Location location = object.function->location;
            std::string text = "nil";
            if (object.declaration)
            {
                location = object.declaration->location;
                if (auto* local = object.declaration->as<AstStatLocalFunction>())
                    text = std::string("local ") + local->name->name.value + "=nil";
                else
                {
                    auto* function = object.declaration->as<AstStatFunction>();
                    const size_t start = offset(source, function->name->location.begin);
                    const size_t end = offset(source, function->name->location.end);
                    text.assign(source.source + start, end - start);
                    std::replace(text.begin(), text.end(), ':', '.');
                    text += "=nil";
                    if (removableField(function->name, object.module))
                        text.clear();
                }
            }
            const size_t start = offset(source, location.begin);
            size_t end = offset(source, location.end);
            if (text.empty())
            {
                size_t next = end;
                while (next < source.sourceSize && (source.source[next] == ' ' || source.source[next] == '\t' ||
                    source.source[next] == '\r' || source.source[next] == '\n'))
                    ++next;
                if (next < source.sourceSize && source.source[next] == ';')
                    end = next + 1;
            }
            if (end <= start || text.size() > end - start)
                continue;
            bool preservesLines = true;
            for (size_t index = 0; index < text.size(); ++index)
                if (source.source[start + index] == '\n' || source.source[start + index] == '\r' ||
                    text[index] == '\n' || text[index] == '\r')
                    preservesLines = false;
            if (preservesLines)
                edits[object.module].push_back({start, end, std::move(text)});
        }
        for (size_t index = 0; index < count; ++index)
        {
            auto& list = edits[index];
            if (list.empty())
                continue;
            std::sort(list.begin(), list.end(), [](const Edit& left, const Edit& right) {
                return left.start == right.start ? left.end > right.end : left.start < right.start;
            });
            auto& source = sources[index];
            source.rewritten = static_cast<char*>(malloc(source.sourceSize));
            if (!source.rewritten)
                continue;
            memcpy(source.rewritten, source.source, source.sourceSize);
            size_t end = 0;
            for (const Edit& edit : list)
            {
                if (edit.start < end)
                    continue;
                for (size_t cursor = edit.start; cursor < edit.end; ++cursor)
                    if (source.rewritten[cursor] != '\n' && source.rewritten[cursor] != '\r')
                        source.rewritten[cursor] = ' ';
                memcpy(source.rewritten + edit.start, edit.text.data(), edit.text.size());
                end = edit.end;
            }
        }
    }
};
}

extern "C" void luauc_frontend_prune_package(LuaucLivenessSource* sources, size_t count, size_t entry)
{
    LuaucLiveness::Analysis analysis;
    analysis.run(sources, count, entry);
}

extern "C" void luauc_frontend_free_pruned(LuaucLivenessSource* sources, size_t count)
{
    for (size_t index = 0; index < count; ++index)
    {
        free(sources[index].rewritten);
        sources[index].rewritten = nullptr;
    }
}
