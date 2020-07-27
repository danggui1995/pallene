-- Copyright (c) 2020, The Pallene Developers
-- Pallene is licensed under the MIT license.
-- Please refer to the LICENSE and AUTHORS files for details
-- SPDX-License-Identifier: MIT

local parser = {}

local re = require "relabel"
local inspect = require "inspect"

local ast = require "pallene.ast"
local lexer = require "pallene.lexer"
local location = require "pallene.location"
local syntax_errors = require "pallene.syntax_errors"

-- File name of the file that is currently being parsed. Since this is a global the parser is not
-- reentrant but we couldn't think of a better way yet. (If only lpeg.re had Carg...)
local THIS_FILENAME = nil

--
-- Functions used by the PEG grammar
--

local defs = {}

for token_name, token_pat in pairs(lexer) do
    defs[token_name] = token_pat
end

for type_name, conss in pairs(ast) do
    if type(conss) == "table" then
        for tag, cons in pairs(conss) do
            local name = type_name .. tag
            assert(not defs[name])
            defs[name] = cons
        end
    end
end

function defs.get_loc(s, pos)
    return true, location.from_pos(THIS_FILENAME, s, pos)
end

function defs.to_true()
    return true
end

function defs.to_false()
    return false
end

function defs.opt(x)
    if x == "" then
        return false
    else
        return x
    end
end

function defs.opt_bool(x)
    return x ~= ""
end

function defs.opt_list(x)
    if x == "" then
        return {}
    else
        return x
    end
end

function defs.toplevel_func(loc, is_local, name_loc, name, params, rt_col_loc, ret_types,
    rt_end_loc, block)
    local arg_types = {}
    for i, decl in ipairs(params) do
        arg_types[i] = decl.type
    end
    local func_typ = ast.Type.Function(loc, arg_types, ret_types)
    return ast.Toplevel.Func(
        loc, is_local, name_loc,
        ast.Decl.Decl(loc, name, false, func_typ, false),
        ast.Exp.Lambda(loc, params, block), rt_col_loc, rt_end_loc)
end

function defs.nil_exp(pos--[[, s ]])
    -- We can't call ast.Exp.Nil directly in the parser because we need to drop the string capture
    -- that comes in the second argument.
    return ast.Exp.Nil(pos)
end

function defs.number_exp(pos, n)
    if math.type(n) == "integer" then
        return ast.Exp.Integer(pos, n)
    elseif math.type(n) == "float" then
        return ast.Exp.Float(pos, n)
    else
        error("impossible")
    end
end

function defs.name_exp(pos, name)
    return ast.Exp.Var(pos, ast.Var.Name(pos, name))
end

function defs.if_stat(pos, exp, block, else_ifs, else_opt)
    local else_ = else_opt or ast.Stat.Block(pos, {})

    for i = #else_ifs, 1, -1 do
        local e = else_ifs[i]
        else_ = ast.Stat.If(e.pos, e.exp, e.block, else_)
    end

    return ast.Stat.If(pos, exp, block, else_)
end

function defs.elseif_(pos, exp, block)
    return { pos = pos, exp = exp, block = block }
end

function defs.fold_binop_left(exp, matches)
    for i = 1, #matches, 3 do
        local pos = matches[i]
        local op  = matches[i+1]
        local rhs = matches[i+2]
        exp = ast.Exp.Binop(pos, exp, op, rhs)
    end
    return exp
end

-- Should this go on a separate constant propagation pass?
function defs.binop_concat(lhs, pos, op, rhs)
    if op then
        if rhs._tag == "ast.Exp.Concat" then
            table.insert(rhs.exps, 1, lhs)
            return rhs
        elseif (lhs._tag == "ast.Exp.String" or
            lhs._tag == "ast.Exp.Integer" or
            lhs._tag == "ast.Exp.Float") and
            (rhs._tag == "ast.Exp.String" or
            rhs._tag == "ast.Exp.Integer" or
            rhs._tag == "ast.Exp.Float") then
            return ast.Exp.String(pos, lhs.value .. rhs.value)
        else
            return ast.Exp.Concat(pos, { lhs, rhs })
        end
    else
        return lhs
    end
end

function defs.binop_right(lhs, pos, op, rhs)
    if op then
        return ast.Exp.Binop(pos, lhs, op, rhs)
    else
        return lhs
    end
end

function defs.fold_unops(matches, exp)
    for i = #matches, 1, -2 do
        local op  = matches[i]
        local pos = matches[i-1]
        exp = ast.Exp.Unop(pos, op, exp)
    end
    return exp
end

function defs.fold_casts(exp, matches)
    for i = 1, #matches, 3 do
        local target_start_loc = matches[i]
        local target = matches[i + 1]
        local target_end_loc = matches[i + 2]
        exp = ast.Exp.Cast(target_start_loc, exp, target, target_end_loc)
    end
    return exp
end

-- We represent the suffix of an expression by a function that receives the base expression and
-- returns a full expression including the suffix.

function defs.suffix_func_call(pos, args)
    return function(exp)
        return ast.Exp.CallFunc(pos, exp,  args)
    end
end

function defs.suffix_method_call(pos, name, args)
    return function(exp)
        return ast.Exp.CallMethod(pos, exp, name, args)
    end
end

function defs.suffix_bracket(pos, index)
    return function(exp)
        return ast.Exp.Var(pos, ast.Var.Bracket(pos, exp, index))
    end
end

function defs.suffix_dot(pos, name)
    return function(exp)
        return ast.Exp.Var(pos, ast.Var.Dot(pos, exp, name))
    end
end

function defs.fold_suffixes(exp, suffixes)
    for i = 1, #suffixes do
        local suf = suffixes[i]
        exp = suf(exp)
    end
    return exp
end

function defs.exp_to_var(exp)
    return exp.var
end

function defs.exp_is_var(_, pos, exp)
    if exp._tag == "ast.Exp.Var" then
        return pos, exp
    else
        return false
    end
end

function defs.exp_is_call(_, pos, exp)
    if exp._tag == "ast.Exp.CallFunc" or
       exp._tag == "ast.Exp.CallMethod" then
        return pos, exp
    else
        return false
    end
end

local grammar = re.compile([[

    program         <-  SKIP*
                        {|
                           ( toplevelfunc
                           / toplevelvar
                           / typealias
                           / toplevelrecord
                           / import
                           / FUNCTION %{LocalOrExportRequiredFunction}
                           / NAME (ASSIGN / COMMA) %{LocalOrExportRequiredVariable} )*
                        |} !.

    toplevelfunc    <- (P  export_or_local FUNCTION P NAME^NameFunc
                           LPAREN^LParPList paramlist RPAREN^RParPList
                           P rettypeopt P block END^EndFunc)         -> toplevel_func

    toplevelvar     <- (P  export_or_local decllist ASSIGN^AssignVar
                           !IMPORT explist1^ExpVarDec)           -> ToplevelVar

    typealias       <- (P  TYPEALIAS NAME^NameTypeAlias ASSIGN^AssignTypeAlias
                           type^TypeTypeAlias P)                   -> ToplevelTypealias

    toplevelrecord  <- (P  RECORD NAME^NameRecord recordfields
                           END^EndRecord P)                        -> ToplevelRecord

    export_or_local <- LOCAL -> to_true
                    / EXPORT -> to_false

    import          <- (P  LOCAL NAME^NameImport ASSIGN^AssignImport
                           IMPORT^ImportImport
                          (LPAREN STRINGLIT^StringLParImport RPAREN^RParImport /
                          STRINGLIT^StringImport))               -> ToplevelImport

    rettypeopt      <- (COLON rettype^TypeFunc)?                 -> opt_list

    paramlist       <- {| (param (COMMA param^DeclParList)*)? |} -- produces {Decl}

    param           <- (P  NAME P COLON^ParamSemicolon
                           type^TypeDecl P)                        -> DeclDecl

    decl            <- (P  NAME P ((COLON type^TypeDecl)? -> opt) P)   -> DeclDecl

    simpletype      <- (P  NIL)                                  -> TypeNil
                     / (P  BOOLEAN)                              -> TypeBoolean
                     / (P  INTEGER)                              -> TypeInteger
                     / (P  FLOAT)                                -> TypeFloat
                     / (P  STRING)                               -> TypeString
                     / (P  ANY)                                  -> TypeAny
                     / (P  NAME)                                 -> TypeName
                     / (P  LCURLY tablefields RCURLY^RCurlyType) -> TypeTable
                     / (P  LCURLY type^TypeType
                           RCURLY^RCurlyType)                    -> TypeArray

    typelist        <- ( LPAREN
                         {| (type (COMMA type^TypelistType)*)? |}
                         RPAREN^RParenTypelist )                 -- produces {Type}

    rettype         <- {| (P  typelist RARROW
                            rettype^TypeReturnTypes)             -> TypeFunction |}
                     / {| (P  {| simpletype |} RARROW
                             rettype^TypeReturnTypes)            -> TypeFunction |}
                     / typelist
                     / {| simpletype |}

    type            <- (P  typelist RARROW
                           rettype^TypeReturnTypes)              -> TypeFunction
                     / (P  {| simpletype |} RARROW
                           rettype^TypeReturnTypes)              -> TypeFunction
                     / simpletype

    tablefields     <- {| tablefield (fieldsep tablefield)*
                          fieldsep? |}                           -- produces {Decl}

    tablefield      <- (P  NAME P COLON type^TypeTableField P)       -> DeclDecl

    recordfields    <- {| recordfield* |}                        -- produces {Decl}

    recordfield     <- (P  NAME P COLON^ColonRecordField
                           type^TypeRecordField P SEMICOLON?)      -> DeclDecl

    block           <- (P  {| statement* returnstat? |})         -> StatBlock

    statement       <- (SEMICOLON)                               -- ignore
                     / (DO block END^EndBlock)                   -- produces StatBlock
                     / (P  WHILE exp^ExpWhile DO^DoWhile
                                 block END^EndWhile)             -> StatWhile
                     / (P  REPEAT block UNTIL^UntilRepeat
                                      exp^ExpRepeat)             -> StatRepeat
                     / (P  IF exp^ExpIf THEN^ThenIf block
                           elseifstats elseopt END^EndIf)        -> if_stat
                     / (P  FOR decl^DeclFor
                           ASSIGN^AssignFor exp^Exp1For
                           COMMA^CommaFor exp^Exp2For
                           (COMMA exp^Exp3For)?                  -> opt
                           DO^DoFor block END^EndFor)            -> StatFor
                     / (P  LOCAL decllist^DeclLocal
                            (ASSIGN
                                explist1^ExpLocal)? -> opt_list) -> StatDecl
                     / (P  BREAK)                                -> StatBreak
                     / (P  varlist ASSIGN^AssignAssign
                               explist1^ExpAssign)               -> StatAssign
                     / &(exp ASSIGN) %{AssignNotToVar}
                     / (P  (suffixedexp => exp_is_call))         -> StatCall
                     / &exp %{ExpStat}

    elseifstats     <- {| elseifstat* |}                         -- produces {elseif}

    elseifstat      <- (P  ELSEIF exp^ExpElseIf
                           THEN^ThenElseIf block)                -> elseif_

    elseopt         <- (ELSE block)?                             -> opt

    returnstat      <- (P  RETURN explist0 SEMICOLON?)           -> StatReturn

    op1             <- ( OR -> 'or' )
    op2             <- ( AND -> 'and' )
    op3             <- ( EQ -> '==' / NE -> '~=' / LT -> '<' /
                         GT -> '>'  / LE -> '<=' / GE -> '>=' )
    op4             <- ( BOR -> '|' )
    op5             <- ( BXOR -> '~' )
    op6             <- ( BAND -> '&' )
    op7             <- ( SHL -> '<<' / SHR -> '>>' )
    op8             <- ( CONCAT -> '..' )
    op9             <- ( ADD -> '+' / SUB -> '-' )
    op10            <- ( MUL -> '*' / MOD -> '%%' / DIV -> '/' / IDIV -> '//' )
    unop            <- ( NOT -> 'not' / LEN -> '#' / NEG -> '-' / BNEG -> '~' )
    op12            <- ( POW -> '^' )

    exp             <- e1
    e1              <- (e2  {| (P op1  e2^OpExp)*  |})           -> fold_binop_left
    e2              <- (e3  {| (P op2  e3^OpExp)*  |})           -> fold_binop_left
    e3              <- (e4  {| (P op3  e4^OpExp)*  |})           -> fold_binop_left
    e4              <- (e5  {| (P op4  e5^OpExp)*  |})           -> fold_binop_left
    e5              <- (e6  {| (P op5  e6^OpExp)*  |})           -> fold_binop_left
    e6              <- (e7  {| (P op6  e7^OpExp)*  |})           -> fold_binop_left
    e7              <- (e8  {| (P op7  e8^OpExp)*  |})           -> fold_binop_left
    e8              <- (e9  (P op8  e8^OpExp)?)                  -> binop_concat
    e9              <- (e10 {| (P op9  e10^OpExp)* |})           -> fold_binop_left
    e10             <- (e11 {| (P op10 e11^OpExp)* |})           -> fold_binop_left
    e11             <- ({| (P unop)* |}  e12)                    -> fold_unops
    e12             <- (e13 (P op12 e11^OpExp)?)                 -> binop_right
    e13             <- (simpleexp {| (P AS type^CastType P)* |}) -> fold_casts

    suffixedexp     <- (prefixexp {| expsuffix* |})              -> fold_suffixes

    expsuffix       <- (P  funcargs)                             -> suffix_func_call
                     / (P  COLON NAME^NameColonExpSuf
                                 funcargs^FuncArgsExpSuf)        -> suffix_method_call
                     / (P  LBRACKET exp^ExpExpSuf
                                RBRACKET^RBracketExpSuf)         -> suffix_bracket
                     / (P  DOT NAME^NameDotExpSuf)               -> suffix_dot

    prefixexp       <- (P  NAME)                                 -> name_exp
                     / (P LPAREN exp^ExpSimpleExp
                               RPAREN^RParSimpleExp)             -> ExpParen

    simpleexp       <- (P  NIL)                                  -> nil_exp
                     / (P  FALSE -> to_false)                    -> ExpBool
                     / (P  TRUE -> to_true)                      -> ExpBool
                     / (P  NUMBER)                               -> number_exp
                     / (P  STRINGLIT)                            -> ExpString
                     / initlist                                  -- produces Exp
                     / suffixedexp                               -- produces Exp

    var             <- (suffixedexp => exp_is_var)               -> exp_to_var

    funcargs        <- (LPAREN explist0 RPAREN^RParFuncArgs)     -- produces {Exp}
                     / {| initlist |}                            -- produces {Exp}
                     / {| (P  STRINGLIT) -> ExpString |}         -- produces {Exp}

    explist0         <- {| (exp (COMMA exp^ExpExpList)*)? |}     -- produces {Exp}

    explist1         <- {| exp (COMMA exp^ExpExpList)* |}        -- produces {Exp}

    varlist         <- {| var (COMMA var^VarVarList)* |}         -- produces {Var}

    decllist         <- {| decl (COMMA decl^DeclDeclList)* |}    -- produces {Decl}

    initlist        <- (P  LCURLY {| fieldlist? |}
                                  RCURLY^RCurlyInitList)         -> ExpInitlist

    fieldlist       <- (field
                        (fieldsep
                         (field /
                          !RCURLY %{ExpFieldList}))*
                        fieldsep?)                          -- produces Field...

    field           <- (P  (NAME ASSIGN)? -> opt exp)       -> FieldField

    fieldsep        <- SEMICOLON / COMMA

    --
    -- Get current position
    --

    P <- {} => get_loc

    -- Create new rules for all our tokens, for the whitespace-skipping magic
    -- I grumply wrote all of these by hand.

    SKIP            <- (%SPACE / %COMMENT)

    AND             <- %AND SKIP*
    BREAK           <- %BREAK SKIP*
    DO              <- %DO SKIP*
    ELSE            <- %ELSE SKIP*
    ELSEIF          <- %ELSEIF SKIP*
    END             <- %END SKIP*
    FALSE           <- %FALSE SKIP*
    FOR             <- %FOR SKIP*
    FUNCTION        <- %FUNCTION SKIP*
    GOTO            <- %GOTO SKIP*
    IF              <- %IF SKIP*
    IN              <- %IN SKIP*
    LOCAL           <- %LOCAL SKIP*
    EXPORT          <- %EXPORT SKIP*
    NIL             <- %NIL SKIP*
    NOT             <- %NOT SKIP*
    OR              <- %OR SKIP*
    RECORD          <- %RECORD SKIP*
    REPEAT          <- %REPEAT SKIP*
    RETURN          <- %RETURN SKIP*
    THEN            <- %THEN SKIP*
    TRUE            <- %TRUE SKIP*
    UNTIL           <- %UNTIL SKIP*
    WHILE           <- %WHILE SKIP*
    IMPORT          <- %IMPORT SKIP*
    AS              <- %AS SKIP*
    TYPEALIAS       <- %TYPEALIAS SKIP*

    BOOLEAN         <- %BOOLEAN SKIP*
    INTEGER         <- %INTEGER SKIP*
    FLOAT           <- %FLOAT SKIP*
    STRING          <- %STRING SKIP*
    ANY             <- %ANY SKIP*

    ADD             <- %ADD SKIP*
    SUB             <- %SUB SKIP*
    MUL             <- %MUL SKIP*
    MOD             <- %MOD SKIP*
    DIV             <- %DIV SKIP*
    IDIV            <- %IDIV SKIP*
    POW             <- %POW SKIP*
    LEN             <- %LEN SKIP*
    BAND            <- %BAND SKIP*
    BXOR            <- %BXOR SKIP*
    BOR             <- %BOR SKIP*
    SHL             <- %SHL SKIP*
    SHR             <- %SHR SKIP*
    CONCAT          <- %CONCAT SKIP*
    EQ              <- %EQ SKIP*
    LT              <- %LT SKIP*
    GT              <- %GT SKIP*
    NE              <- %NE SKIP*
    LE              <- %LE SKIP*
    GE              <- %GE SKIP*
    ASSIGN          <- %ASSIGN SKIP*
    LPAREN          <- %LPAREN SKIP*
    RPAREN          <- %RPAREN SKIP*
    LBRACKET        <- %LBRACKET SKIP*
    RBRACKET        <- %RBRACKET SKIP*
    LCURLY          <- %LCURLY SKIP*
    RCURLY          <- %RCURLY SKIP*
    SEMICOLON       <- %SEMICOLON SKIP*
    COMMA           <- %COMMA SKIP*
    DOT             <- %DOT SKIP*
    DOTS            <- %DOTS SKIP*
    DBLCOLON        <- %DBLCOLON SKIP*
    COLON           <- %COLON SKIP*
    RARROW          <- %RARROW SKIP*

    NUMBER          <- %NUMBER SKIP*
    STRINGLIT       <- %STRINGLIT SKIP*
    NAME            <- %NAME SKIP*

    -- Synonyms

    NEG             <- SUB
    BNEG            <- BXOR

]], defs)

local function syntax_error(loc, err_msg)
    return location.format_error(loc, "syntax error: %s", err_msg)
end

local function find_breaks_outside_loops(root_stat)
    local bad_breaks = {}
    local function find_errors(stat)
        local tag = stat._tag
        if     tag == "ast.Stat.Break" then
            table.insert(bad_breaks, stat)
        elseif tag == "ast.Stat.Block" then
            for i = 1, #stat.stats do
                find_errors(stat.stats[i])
            end
        elseif tag == "ast.Stat.If" then
            find_errors(stat.then_)
            find_errors(stat.else_)
        end
    end
    find_errors(root_stat)
    return bad_breaks
end


function parser.parse(file_name, input)
    -- Abort if someone calls this non-reentrant parser recursively
    assert(type(file_name) == "string")
    assert(THIS_FILENAME == nil)

    THIS_FILENAME = file_name
    local prog_ast, err, errpos = grammar:match(input)
    THIS_FILENAME = nil

    if not prog_ast then
        local loc = location.from_pos(file_name, input, errpos)
        local errors = { syntax_error(loc, syntax_errors.errors[err]) }
        return false, errors
    end

    local break_errors = {}
    for _, tl_node in ipairs(prog_ast) do
        if tl_node._tag == "ast.Toplevel.Func" then
            local body = tl_node.value.body
            for _, stat in ipairs(find_breaks_outside_loops(body)) do
                table.insert(break_errors,
                    syntax_error(stat.loc, "break statement outside loop"))
            end
        end
    end
    if #break_errors > 0 then
        return false, break_errors
    end

    return prog_ast, {}
end

function parser.pretty_print_ast(prog_ast)
    return inspect(prog_ast, {
        process = function(item, path)
            if path[#path] ~= inspect.METATABLE then
                return item
            end
        end
    })
end

return parser
