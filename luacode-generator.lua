local operator = require("operator")

local StatementRule = { }
local ExpressionRule = { }

local concat = table.concat
local format = string.format

local function is_string(node)
    return node.kind == "Literal" and type(node.value) == "string"
end

local function comma_sep_list(ls, f)
    local strls
    if f then
        strls = { }
        for k = 1, #ls do strls[k] = f(ls[k]) end
    else
        strls = ls
    end
    return concat(strls, ", ")
end

local function as_parameter(node)
    return node.kind == "Vararg" and "..." or node.name
end

function
 ExpressionRule:Identifier(node)
    return node.name, operator.ident_priority
end

function ExpressionRule:Literal(node)
    local val = node.value
    local str = type(val) == "string" and format("%q", val) or tostring(val)
    return str, operator.ident_priority
end

function ExpressionRule:MemberExpression(node)
    local object, prio = self:expr_emit(node.object)
    if prio < operator.ident_priority then object = "(" .. object .. ")" end
    local exp
    if node.computed then
        local prop = self:expr_emit(node.property)
        exp = format("%s[%s]", object, prop)
    else
        exp = format("%s.%s", object, node.property.name)
    end
    return exp, operator.ident_priority
end

function ExpressionRule:BinaryExpression(node)
    local oper = node.operator
    local prio = operator.left_priority(oper)
    local a, a_prio = self:expr_emit(node.left)
    local b, b_prio = self:expr_emit(node.right)
    local ap = a_prio < prio and format("(%s)", a) or a
    local bp = b_prio < prio and format("(%s)", b) or b
    return format("%s %s %s", ap, oper, bp), prio
end

function ExpressionRule:Table(node, dest)
    local array = self:expr_list(node.array_entries)
    local hash = { }
    for k = 1, #node.hash_keys do
        local key = node.hash_keys[k]
        local value = self:expr_emit(node.hash_values[k])
        if is_string(key) then
            hash[k] = format("%s = %s", key.value, value)
        else
            hash[k] = format("[%s] = %s", self:expr_emit(key), value)
        end
    end
    local hash_str = comma_sep_list(hash)
    local cont = array == "" and hash_str or array .. ", " .. hash_str
    return "{" .. cont .. "}", operator.ident_priority
end

function ExpressionRule:CallExpression(node, want, tail)
    local callee, prio = self:expr_emit(node.callee)
    if prio < operator.ident_priority then
        callee = "(" .. callee .. ")"
    end
    local exp = format("%s(%s)", callee, self:expr_list(node.arguments))
    return exp, operator.ident_priority
end

function StatementRule:FunctionDeclaration(node)
    local header = format("function %s(%s)", node.id.name, comma_sep_list(node.params, as_parameter))
    if node.locald then
        header = "local " .. header
    end
    self:add_section(header, node.body)
end

function ExpressionRule:FunctionExpression(node)
    local header = format("function(%s)", comma_sep_list(node.params, as_parameter))
    error("NYI")
    -- self:add_section(header, node.body)
end

function StatementRule:CallExpression(node)
    local line = self:expr_emit(node)
    self:add_line(line)
end

function StatementRule:ForStatement(node)
    local init = node.init
    local istart = self:expr_emit(init.value)
    local iend = self:expr_emit(node.last)
    local header
    if init.step then
        local step = self:expr_emit(node.step)
        header = format("for %s = %s, %s, %s do", init.id.name, istart, iend, step)
    else
        header = format("for %s = %s, %s do", init.id.name, istart, iend)
    end
    self:add_section(header, node.body)
end

function StatementRule:IfStatement(node)
    local ncons = #node.tests
    for i = 1, ncons do
        local header_tag = i == 1 and "if" or "elseif"
        local test = self:expr_emit(node.tests[i])
        local header = format("%s %s then", header_tag, test)
        self:add_section(header, node.cons[i], true)
    end
    if node.alternate then
        self:add_section("else", node.alternate, true)
    end
    self:add_line("end")
end

function StatementRule:LocalDeclaration(node)
    local line
    local names = comma_sep_list(node.names, as_parameter)
    if #node.expressions > 0 then
        line = format("local %s = %s", names, self:expr_list(node.expressions))
    else
        line = format("local %s", names)
    end
    self:add_line(line)
end

function StatementRule:AssignmentExpression(node)
    local line = format("%s = %s", self:expr_list(node.left), self:expr_list(node.right))
    self:add_line(line)
end

function StatementRule:Chunk(node)
    self:list_emit(node.body)
end

function StatementRule:BlockStatement(node)
    self:list_emit(node.body)
end

function StatementRule:ExpressionStatement(node)
    local line = self:expr_emit(node.expression)
    self:add_line(line)
end

function StatementRule:ReturnStatement(node)
    local line = format("return %s", self:expr_list(node.arguments))
    self:add_line(line)
end

local function generate(tree, name)

    local self = { line = 0, code = { }, indent = 0 }
    self.chunkname = tree.chunkname

    local function to_expr(node)
        return self:expr_emit(node)
    end

    function self:compile_code()
        return concat(self.code, "\n")
    end

    function self:indent_more()
        self.indent = self.indent + 1
    end

    function self:indent_less()
        self.indent = self.indent - 1
    end

    function self:line(line)
        -- FIXME: ignored for the moment
    end

    function self:add_line(line)
        local indent = string.rep("    ", self.indent)
        self.code[#self.code + 1] = indent .. line
    end

    function self:add_section(header, body, omit_end)
        self:add_line(header)
        self:indent_more()
        self:emit(body)
        self:indent_less()
        if not omit_end then
            self:add_line("end")
        end
    end

    function self:expr_emit(node)
        local rule = ExpressionRule[node.kind]
        return rule(self, node)
    end

    function self:expr_list(exps)
        return comma_sep_list(exps, to_expr)
    end

    function self:emit(node)
        local rule = StatementRule[node.kind]
          if not rule then error("cannot find a statement rule for " .. node.kind) end
          rule(self, node)
          if node.line then self:line(node.line) end
    end

    function self:list_emit(node_list)
        for i = 1, #node_list do
            self:emit(node_list[i])
        end
    end

    self:emit(tree)

    return self:compile_code()
end

return generate
