local m = require "lpeglabel"
local peg = require "peg-parser"
local re = require "relabel"

local Predef = { nl = m.P"\n" }
local mem = {} -- for compiled grammars


local function updatelocale()
	m.locale(Predef)
	local any = m.P(1)
	Predef.a = Predef.alpha
	Predef.c = Predef.cntrl
	Predef.d = Predef.digit
	Predef.g = Predef.graph
	Predef.l = Predef.lower
	Predef.p = Predef.punct
	Predef.s = Predef.space
	Predef.u = Predef.upper
	Predef.w = Predef.alnum
	Predef.x = Predef.xdigit
	Predef.A = any - Predef.a
	Predef.C = any - Predef.c
	Predef.D = any - Predef.d
	Predef.G = any - Predef.g
	Predef.L = any - Predef.l
	Predef.P = any - Predef.p
	Predef.S = any - Predef.s
	Predef.U = any - Predef.u
	Predef.W = any - Predef.w
	Predef.X = any - Predef.x
	mem = {}
end

updatelocale()

local definitions = {}
local tlabels = {}

-- lpeglabel related functions:
local function sync (patt)
	return (-patt * l.P(1))^0 -- skip until we find pattern
end

local SPACES = (Predef.space + Predef.nl)
local SYNCS = (Predef.nl)^0

local recovery = true
local skipspaces = true



local function setSync(patt)
	SYNCS = patt^0
end
local function nocap (s,i,caps)
	return i + #caps
end
local sp = {}
local processed = 0
local function registerspaces(s,i,caps)
	sp[i] = true
	return i
end

local s = require "stack"
-- create stack for tokens inside captures. nil - not inside capture, 0 - inside capture, 1 - token found inside capture
stack = Stack:Create()

local function token (patt)
	local incapture = stack:pop() -- returns nil if not in capture
	if not incapture and skipspaces then
		return patt * SPACES^0
	end
	stack:push(1)
	return patt
end

local function try (patt, err)
	return patt + T(err)
end

local function throws (patt,err) -- if pattern is matched throw error
	return patt * T(err)
end

-- end

-- functions used by the tool

local function iscompiled (gr)
	return m.type(gr) == "pattern"
end

local function istoken (t)
	return t["token"] == "1"
end

local function isfinal(t)
	if t["t"] or t["nt"] or t["func"] or t["s"] then
		return true
	else
		return false
	end
end

local function isaction(t)
	if t["action"] then
		return true
	else
		return false
	end
end


local function isrule(t)
	if not t then return false end
	if t["rulename"] then
		return true
	else
		return false
	end
end
local function isgrammar(t)
	if type(t) == "table" and not(t["action"]) then
		return isrule(t[1])
	else
		return false
	end
end
local function iscapture (action)
	if action == "=>" or action == "tcap" or action == "gcap" or action == "scap" or action == "subcap" or action == "poscap" then
		return true
	else
		return false
	end
end
local function finalNode (t)
	if t["t"] then
		return "t", t["t"] -- terminal
	elseif t["nt"] then
		return "nt", t["nt"], istoken(t) -- nonterminal
	elseif t["func"] then
		return "func", t["func"] -- function
	elseif t["s"] then
		return "s", t["s"]
	else
		return nil
	end
end
local function specialrules(t, builder)
	-- initialize values
	SPACES = (Predef.space + Predef.nl)
	skipspaces = true
	SYNCS = (Predef.nl)^0
	recovery = true
	-- find SPACE and SYNC rules
	for i, v in ipairs(ast) do
		local name = v["rulename"]
		local rule
		if name == "SPACES" then
			rule = traverse(v["rule"], true)
			if v["rule"]["t"] == '' then
				skipspaces = false
			else
				skipspaces = true
				SPACES = (rule) -- todo: traverse rhs for nonterminals
			end
			builder[name] = rule
		elseif name == "SYNC" then
			rule = traverse(v["rule"], true)
			if m.match(rule, '') then -- SYNC <- ''
				recovery=false
			else
				recovery= true
				setSync(rule)
			end
			builder[name] = rule
		end
	end
end

local function buildgrammar (ast)
	local builder = {}
	specialrules(ast, builder)
	for i, v in ipairs(ast) do
		local istokenrule = v["token"] == "1"
		local name = v["rulename"]
		local rule = v["rule"]
		if i == 1 then
			table.insert(builder, name) -- lpeg syntax
			if not builder[name] then
				if skipspaces then
					builder[name] = SPACES^0 * traverse(rule, istokenrule) -- skip spaces at the beginning of the input
				else
					builder[name] = traverse(rule, istokenrule)
				end
			end
		else
			if not builder[name] then -- dont traverse rules for SKIP and SPACES twice
				builder[name] = traverse(rule, istokenrule)
			end
		end
		
	end
	return builder
end
local function equalcap (s, i, c)
  if type(c) ~= "string" then return nil end
  local e = #c + i
  if s:sub(i, e - 1) == c then return e else return nil end
end


local function addspaces (caps)
	local hastoken = stack:pop()
	if hastoken == 1 and skipspaces then
		return caps * SPACES^0
	end
	return caps
end

local function applyaction(action, op1, op2, labels,tokenrule)
	if action == "or" then
		if labels then
			return m.Rec(op1,op2,labels)
		else
			return op1 + op2
		end
	elseif action == "and" then
		return op1 * op2
	elseif action == "&" then
		return #op1
	elseif action == "!" then
		return -op1
	elseif action == "+" then
		return op1^1
	elseif action == "*" then
		return op1^0
	elseif action == "?" then
		return op1^-1
	elseif action == "^" then
		return op1^op2
	elseif action == "->" then
		return op1 / op2
	-- in captures we remove spaces
	elseif action == "=>" then
		return addspaces(m.Cmt(op1,op2))
	elseif action == "tcap" then
		return addspaces(m.Ct(op1))
	elseif action == "gcap" then
		return addspaces(m.Cg(op1, op2))
	elseif action == "bref" then
		return m.Cmt(m.Cb(op1), equalcap) -- do we need to add spaces to bcap?
	elseif action == "poscap" then
		return addspaces(m.Cp())
	elseif action == "subcap" then
		return addspaces(m.Cs(op1))
	elseif action == "scap" then
		return addspaces(m.C(op1)) 
	elseif action == "anychar" then
		return m.P(1)
	elseif action == "label" then
		return m.T(op1) -- lpeglabel
	elseif action == "%" then
		if Predef[op1] then
			return Predef[op1]
		end
		return definitions[op1]
	elseif action == "invert" then
		return m.P(1) - op1
	elseif action == "range" then
		if not tokenrule then
			return token(m.R(op1))
		else
			return m.R(op1)
		end
	else
		error("Unsupported action '"..action.."'")
	end
end

local function applyfinal(action, term, tokenterm, tokenrule)

	if action == "t" then
		if skipspaces and (not tokenrule) then
			return token(m.P(term))
		else
			return m.P(term)
		end
	elseif action == "nt" then
		if skipspaces and tokenterm and (not tokenrule) then
			return token(m.V(term))
		else
			return m.V(term)
		end
	elseif action == "func" then
		return definitions[term]
	elseif action == "s" then -- simple string
		return term
	end
end


local function applygrammar(gram)
	return m.P(gram)
end


local function build(ast, defs)
	if defs then
		definitions = defs
	end
	if isgrammar(ast) then
		return traverse(ast)
	else
		return SPACES^0 * traverse(ast)
	end
end


function traverse (ast, tokenrule)
	if not ast then
		return nil 
	end

	if isfinal(ast) then
		local typefn, fn, tok = finalNode(ast)
		return applyfinal(typefn, fn, tok, tokenrule)
		
	elseif isaction(ast) then
	
		local act, op1, op2, labs, ret1, ret2
		act = ast["action"]
		op1 = ast["op1"]
		op2 = ast["op2"]
		labs = ast["condition"] -- recovery operations
		
		-- post-order traversal
		if iscapture(act) then
			stack:push(0) -- not found any tokens yet
		end
		
		ret1 = traverse(op1, tokenrule)
		ret2 = traverse(op2, tokenrule)
	
		
		return applyaction(act, ret1, ret2, labs, tokenrule)
		
	elseif isgrammar(ast) then
		--
		local g = buildgrammar (ast)
		return applygrammar (g)
		
	else
		peg.print_r(ast)
		error("Unsupported AST")	
	end

end
function traversefortable (ast,rulename)
	if not ast then
		return false
	end
	if isfinal(ast) then
		if rulename and ast["nt"] == rulename then
			return true
		end
		return false
	end
	if isaction(ast) then
		if ast["action"] == "tcap" then
			return true
		end
		ret1 = traversefortable(ast["op1"])
		ret2 = traversefortable(ast["op2"])
		return ret1 or ret2
	else
		return false
	end
end

local function preprocess_aux (ast,ruletable)
	
	if not ast then
		return false
	elseif isgrammar(ast) then
		return preprocess(ast)
	elseif isfinal(ast) then
		return ast
	elseif isaction(ast) then
		if iscapture(ast) then
			error("cap")
			for k,v in pairs(ruletable) do 
				print(v)
				if traversefortable(ast, v) then
					error("Found it!")
					ast["nosub"] = 1
				end
			end
        else
			ast["op1"] = preprocess_aux(ast["op1"],ruletable)
			ast["op2"] = preprocess_aux(ast["op2"],ruletable)
		end
	end
	return ast
end
local function preprocess (ast)
	local rulehastable = {}
	if isgrammar(ast) then
		for k,v in pairs(ast) do 
            local rulename = v["rulename"]
			local rule = v["rule"]
			if traversefortable(rule) then
				rulehastable[rulename] = true
			end
        end
		for k,v in pairs(ast) do 
			local rule = v["rule"]
			v["rule"] = preprocess_aux(rule)
        end
		return ast
	end
	return preprocess_aux(ast)
end
local function compile (input, defs)
	if iscompiled(input) then 
		return input 
	end
	if not mem[input] then
		-- test for errors
		re.setlabels(labels)
		re.compile(input,defs)
		-- build ast
		ast = peg.pegToAST(input)
		--peg.print_r(ast)
		--print("AFTER")
		-- add nosubs fields
		--ast = preprocess(ast)
		--peg.print_r(ast)
		-- rebuild lpeg grammar
		ret = build(ast,defs)
		
		mem[input] = ret -- store if the user forgets to compile it
	end
	return mem[input]
end

local function setlabels (t)
	return peg.setlabels(t)
end
function lpeggsub (s, patt, repl)
  patt = m.Cs((patt / repl + 1)^0)
  return m.match(patt, s)
end

function removespaces (t)
    if type(t) == "table" then
		print("table!")
        for k,v in pairs(t) do -- for every element in the table
            t[k] = removespaces(v)       -- recursively repeat the same procedure
        end
    else 
        res = lpeggsub(t,SPACES,'')
		t = res
    end
	return t
end

local function parse (input, grammar, defs, errorfunction)
	sp = {}
	if not iscompiled(grammar) then
		cp = compile(grammar,defs)
		grammar = cp
	end
	local r, e, sfail = m.match(grammar,input)
	if not r then
		local line, col = re.calcline(input, #input - #sfail)
		local msg = "Error at line " .. line .. " (col " .. col .. "): "
		local err
		if e == 0 then 
			err = "Syntax error"
		else 
			err = errmsgs[e]
		end
		return r, msg ..  err .. " before '" .. sfail .. "'"
	end
	
	--if skipspaces then
	--	r = removespaces(r)
	--end
	return r
end

local pg = {compile=compile, setlabels=setlabels, parse=parse}

return pg