-- Copyright (c) 2020, The Pallene Developers
-- Pallene is licensed under the MIT license.
-- Please refer to the LICENSE and AUTHORS files for details
-- SPDX-License-Identifier: MIT

local c_compiler = require "pallene.c_compiler"
local checker = require "pallene.checker"
local constant_propagation = require "pallene.constant_propagation"
local coder = require "pallene.coder"
local parser = require "pallene.parser"
local to_ir = require "pallene.to_ir"
local uninitialized = require "pallene.uninitialized"
local util = require "pallene.util"
local translator = require "pallene.translator"

local driver = {}

local function check_source_filename(argv0, file_name, expected_ext)
    local name, ext = util.split_ext(file_name)
    if ext ~= expected_ext then
        local msg = string.format("%s: %s does not have a .%s extension",
            argv0, file_name, expected_ext)
        return false, msg
    end
    if not string.match(name, "^[a-zA-Z0-9_/]+$") then
        local msg = string.format("%s: filename %s is non-alphanumeric",
            argv0, file_name)
        return false, msg
    end
    return name
end

function driver.load_input(path)
    local base_name, err = check_source_filename("pallenec test", path, "pln")
    if not base_name then
        return false, err
    end
    return util.get_file_contents(path)
end

--
-- Run AST and IR passes, up-to and including the specified pass. This is meant for unit tests.
--
function driver.compile_internal(filename, input, stop_after, opt_passes)
    stop_after = stop_after or "optimize"

    local prog_ast, errs = parser.parse(filename, input)
    if stop_after == "ast" or not prog_ast then
        return prog_ast, errs
    end

    prog_ast, errs = checker.check(prog_ast)
    if stop_after == "checker" or not prog_ast then
        return prog_ast, errs
    end

    local module
    module, errs = to_ir.convert(prog_ast)
    if stop_after == "ir" or not module then
        return module, errs
    end

    if stop_after ~= "optimize" or opt_passes["uninitialized"] then
        module, errs = uninitialized.verify_variables(module)
        if stop_after == "uninitialized" or not module then
            return module, errs
        end
    end

    if stop_after ~= "optimize" or opt_passes["constant_propagation"] then
        module, errs = constant_propagation.run(module)
        if stop_after == "constant_propagation" or not module then
            return module, errs
        end
    end

    if stop_after == "optimize" or not module then
        return module, {}
    end

    error("impossible")
end

local function compile_pallene_to_c(pallene_filename, c_filename, mod_name, opt_passes)
    local input, err = driver.load_input(pallene_filename)
    if not input then
        return false, { err }
    end

    local module, errs = driver.compile_internal(pallene_filename, input, nil, opt_passes)
    if not module then
        return false, errs
    end

    local c_code
    c_code, errs = coder.generate(module, mod_name)
    if not c_code then
        return false, errs
    end

    local ok
    ok, err = util.set_file_contents(c_filename, c_code)
    if not ok then
        return false, { err }
    end

    return true, {}
end

local compiler_steps = {
    { name = "pln", f = compile_pallene_to_c },
    { name = "c",   f = c_compiler.compile_c_to_s },
    { name = "s",   f = c_compiler.compile_s_to_o },
    { name = "o",   f = c_compiler.compile_o_to_so},
    { name = "so",  f = false },
}
local step_index = {}
for i = 1, #compiler_steps do
    step_index[compiler_steps[i].name] = i
end

--
-- Compile an input file with extension [input_ext] to an output file of type [output_ext].
-- Erases any intermediate files that are produced along the way.
--
-- Example:
--    compile("pln", "so", "foo.pln") --> outputs "foo.so"
--    compile("pln", "c", "foo.pln")  --> outputs "foo.c"
--    compile("c", "so", "foo.c)      --> outputs "foo.so"
--

local function compile_pln_to_lua(input_ext, output_ext, input_file_name, base_name)
    assert(input_ext == "pln")

    local input, err = driver.load_input(input_file_name)
    if not input then
        return false, { err }
    end

    local prog_ast, errs = driver.compile_internal(input_file_name, input, "checker")
    if not prog_ast then
        return false, errs
    end

    local translation = translator.translate(input, prog_ast)

    assert(util.set_file_contents(base_name .. "." .. output_ext, translation))
    return true, {}
end

function driver.compile(argv0, input_ext, output_ext, input_file_name, opt_passes)
    local base_name, err =
        check_source_filename(argv0, input_file_name, input_ext)
    if not base_name then return false, {err} end

    local mod_name = string.gsub(base_name, "/", "_")

    if output_ext == "lua" then
        return compile_pln_to_lua(input_ext, output_ext, input_file_name, base_name)
    else
        local first_step = step_index[input_ext]  or error("invalid extension")
        local last_step  = step_index[output_ext] or error("invalid extension")
        assert(first_step < last_step, "impossible order")

        local file_names = {}
        for i = first_step, last_step do
            local step = compiler_steps[i]
            if (i == first_step or i == last_step) then
                file_names[i] = base_name .. "." .. step.name
            else
                file_names[i] = os.tmpname()
            end
        end

        local ok, errs
        for i = first_step, last_step-1 do
            local f = compiler_steps[i].f
            local src = file_names[i]
            local out = file_names[i+1]
            ok, errs = f(src, out, mod_name, opt_passes)
            if not ok then break end
        end

        for i = first_step+1, last_step-1 do
            os.remove(file_names[i])
        end

        return ok, errs
    end
end

return driver
