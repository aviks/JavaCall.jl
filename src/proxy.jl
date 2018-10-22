# See documentation for JProxy for infomation

import Base.==

global useVerbose = false
global initialized = false

setVerbose() = global useVerbose = true
clearVerbose() = global useVerbose = false

verbose(args...) = useVerbose && println(args...)

abstract type java_lang end
abstract type interface <: java_lang end

classnamefor(t::Type{<:java_lang}) = classnamefor(nameof(t))
classnamefor(s::Symbol) = classnamefor(string(s))
function classnamefor(s::AbstractString)
    s = replace(s, "___" => "_")
    s = replace(s, "_s_" => "\$")
    replace(s, "_" => ".")
end

_defjtype(a::Type, b::Type) = _defjtype(nameof(a), nameof(b))
function _defjtype(a, b)
    symA = Symbol(a)
    verbose("DEFINING ", string(symA), " ", quote
        abstract type $symA <: $b end
        $symA
    end)
    get!(types, Symbol(classnamefor(a))) do
        #println("DEFINING ", symA)
        eval(quote
             abstract type $symA <: $b  end
             $symA
        end)
    end
end

macro defjtype(expr)
    :(_defjtype($(string(expr.args[1])), $(expr.args[2])))
end

const types = Dict()

@defjtype java_lang_Object <: java_lang
@defjtype java_util_AbstractCollection <: java_lang_Object
@defjtype java_lang_Number <: java_lang_Object
@defjtype java_lang_Double <: java_lang_Number
@defjtype java_lang_Float <: java_lang_Number
@defjtype java_lang_Long <: java_lang_Number
@defjtype java_lang_Integer <: java_lang_Number
@defjtype java_lang_Short <: java_lang_Number
@defjtype java_lang_Byte <: java_lang_Number
@defjtype java_lang_Character <: java_lang_Object
@defjtype java_lang_Boolean <: java_lang_Object

# types
const modifiers = JavaObject{Symbol("java.lang.reflect.Modifier")}
const JField = JavaObject{Symbol("java.lang.reflect.Field")}
const JPrimitive = Union{Bool, Char, UInt8, Int8, UInt16, Int16, Int32, Int64, Float32, Float64}
const JNumber = Union{Int8, Int16, Int32, Int64, Float32, Float64}
const JBoxTypes = Union{
    java_lang_Double,
    java_lang_Float,
    java_lang_Long,
    java_lang_Integer,
    java_lang_Short,
    java_lang_Byte,
    java_lang_Character,
    java_lang_Boolean
}
const JBoxed = Union{
    JavaObject{Symbol("java.lang.Boolean")},
    JavaObject{Symbol("java.lang.Byte")},
    JavaObject{Symbol("java.lang.Character")},
    JavaObject{Symbol("java.lang.Short")},
    JavaObject{Symbol("java.lang.Integer")},
    JavaObject{Symbol("java.lang.Long")},
    JavaObject{Symbol("java.lang.Float")},
    JavaObject{Symbol("java.lang.Double")}
}

struct JavaTypeInfo
    setterFunc
    classname::Symbol # legal classname as a symbol
    signature::AbstractString
    juliaType::Type # the Julia representation of the Java type, like jboolean (which is a UInt8), for call-in
    convertType::Type # the Julia type to convert results to, like Bool or String
    primitive::Bool
    accessorName::AbstractString
    boxType::Type{JavaObject{T}} where T
    boxClass::JClass
    primClass::JClass
    getter::Ptr{Nothing}
    staticGetter::Ptr{Nothing}
    setter::Ptr{Nothing}
    staticSetter::Ptr{Nothing}
end

struct JReadonlyField
    get
end

struct JReadWriteField
    get
    set
end

struct JFieldInfo{T}
    field::JField
    typeInfo::JavaTypeInfo
    static::Bool
    id::Ptr{Nothing}
    owner::JClass
end

struct JMethodInfo
    name::AbstractString
    typeInfo::JavaTypeInfo
    returnType::Symbol # kluge this until we get generate typeInfo properly for new types
    returnClass::JClass
    argTypes::Tuple
    argClasses::Array{JClass}
    id::Ptr{Nothing}
    static::Bool
    owner::JavaMetaClass
    dynArgTypes::Tuple
end

struct JClassInfo
    parent::Union{Nothing, JClassInfo}
    class::JClass
    fields::Dict{Symbol, Union{JFieldInfo, JReadonlyField}}
    methods::Dict{Symbol, Set{JMethodInfo}}
    classtype::Type
end

struct JMethodProxy{N, T}
    pxy # hold onto this so long-held method proxies don't have dead ptr references
    obj::Ptr{Nothing}
    methods::Set
    static::Bool
    function JMethodProxy(N::Symbol, T::Type, pxy, methods)
        new{N, T}(pxy, pxyptr(pxy), methods, pxystatic(pxy))
    end
end

struct Boxing
    info::JavaTypeInfo
    boxType::Type
    boxClass::JClass
    boxClassType::Type
    primClass::JClass
    boxer::Ptr{Nothing}
    unboxer::Ptr{Nothing}
end

"""
    PtrBox(ptr::Ptr{Nothing}

Temporarily holds a globalref to a Java object during JProxy creation
"""
# mutable because it can have a finalizer
mutable struct PtrBox
    ptr::Ptr{Nothing}

    PtrBox(obj::JavaObject) = PtrBox(obj.ptr)
    function PtrBox(ptr::Ptr{Nothing})
        registerlocal(ptr)
        finalizer(finalizebox, new(ptr))
    end
end

"""
    JProxy(s::AbstractString)
    JProxy(::JavaMetaClass)
    JProxy(::Type{JavaObject}; static=false)
    JProxy(obj::JavaObject; static=false)

Create a proxy for a Java object that you can use like a Java object. Field and method syntax is like in Java. Primitive types and strings are converted to Julia objects on field accesses and method returns and converted back to Java types when sent as arguments to Java methods.

*NOTE: Because of this, if you need to call Java methods on a string that you got from Java, you'll have to use `JProxy(str)` to convert the Julia string to a proxied Java string*

To invoke static methods, set static to true.

To get a JProxy's Java object, use `JavaObject(proxy)`

#Example
```jldoctest
julia> a=JProxy(@jimport(java.util.ArrayList)(()))
[]

julia> a.size()
0

julia> a.add("hello")
true

julia> a.get(0)
"hello"

julia> a.isEmpty()
false

julia> a.toString()
"[hello]"

julia> b = a.clone()
[hello]

julia> b.add("derp")
true

julia> a == b
false

julia> b == b
true

julia> JProxy(@jimport(java.lang.System)).getName()
"java.lang.System"

julia> JProxy(@jimport(java.lang.System);static=true).out.println("hello")
hello
```
"""
# mutable because it can have a finalizer
mutable struct JProxy{T, C}
    ptr::Ptr{Nothing}
    info::JClassInfo
    static::Bool
    function JProxy{T, C}(obj::JavaObject, info, static) where {T, C}
        finalizer(finalizeproxy, new{T, C}(newglobalref(obj.ptr), info, static))
    end
    function JProxy{T, C}(obj::PtrBox, info, static) where {T, C}
        finalizer(finalizeproxy, new{T, C}(newglobalref(obj.ptr), info, static))
    end
end

struct GenInfo
    code
    typeCode
    deps
    classList
    methodDicts
    fielddicts
end

struct GenArgInfo
    name::Symbol
    javaType::Type
    juliaType
    spec
end

const JLegalArg = Union{Number, String, JProxy, Array{Number}, Array{String}, Array{JProxy}}
const methodsById = Dict()
const genned = Set()
const emptyset = Set()
const classes = Dict()
const methodCache = Dict{Tuple{String, String, Array{String}}, JMethodInfo}()
const typeInfo = Dict{AbstractString, JavaTypeInfo}()
const boxers = Dict()
const juliaConverters = Dict()
global jnicalls = Dict()
const defaultjnicall = (instance=:CallObjectMethod,static=:CallStaticObjectMethod)
const dynamicTypeCache = Dict()

global genericFieldInfo
global objectClass
global sigTypes

macro jnicall(func, rettype, types, args...)
    #println("TYPE ", rettype)
    quote
        local result = ccall($(esc(func)), $(esc(rettype)),
                       (Ptr{JNIEnv}, $(esc.(types.args)...)),
                       penv, $(esc.(args)...))
        result == C_NULL && geterror()
        $(if rettype == Ptr{Nothing}
              #println("PTR")
              :(registerreturn(result))
          else
              :(result)
          end)
    end
end

macro message(obj, rettype, methodid, args...)
    func = get(jnicalls, rettype, defaultjnicall).instance
    verbose("INSTANCE FUNC: ", func, " RETURNING ", rettype, " ARGS ", typeof.(args))
    flush(stdout)
    #println("TYPE ", rettype)
    quote
        result = ccall(jnifunc.$func, Ptr{Nothing},
                       (Ptr{JNIEnv}, Ptr{Nothing}, Ptr{Nothing}, $((typeof(arg) for arg in args)...)),
                       penv, $(esc(obj)), $(esc(methodid)), $(esc.(args)...))
        result == C_NULL && geterror()
        $(if rettype == Ptr{Nothing}
              #println("PTR")
              :(registerreturn(result))
          else
              :(result)
          end)
    end
end

macro staticmessage(rettype, methodid, args...)
    func = get(jnicalls, rettype, defaultjnicall).static
    verbose("STATIC FUNC: ", func, " RETURNING ", rettype, " ARGS ", typeof.(args))
    flush(stdout)
    #println("TYPE ", rettype)
    quote
        result = ccall(jnifunc.$func, $(esc(rettype)),
                       (Ptr{JNIEnv}, Ptr{Nothing}, $((Ptr{Nothing} for i in args)...)),
                       penv, $(esc(methodid)), $(esc.(args)...))
        result == C_NULL && geterror()
        $(if rettype == Ptr{Nothing}
              #println("PTR")
              :(registerreturn(result))
          else
              :(result)
          end)
    end
end

registerreturn(x) = x
function registerreturn(x::Ptr{Nothing})
    #println("RESULT REF TYPE: ", getreftype(x))
    allocatelocal(x)
end

function arrayinfo(str)
    if (m = match(r"^(\[+)(.)$", str)) != nothing
        signatureClassFor(m.captures[2]), length(m.captures[1])
    elseif (m = match(r"^(\[+)L(.*);", str)) != nothing
        m.captures[2], length(m.captures[1])
    else
        nothing, 0
    end
end

function finalizeproxy(pxy::JProxy)
    ptr = pxyptr(pxy)
    if ptr == C_NULL || penv == C_NULL; return; end
    deleteglobalref(ptr)
    setfield!(pxy, :ptr, C_NULL) #Safety in case this function is called direcly, rather than at finalize
end

function finalizebox(box::PtrBox)
    if box.ptr == C_NULL || penv == C_NULL; return; end
    deleteglobalref(box.ptr)
    box.ptr = C_NULL #Safety in case this function is called direcly, rather than at finalize
end

arraycomponent(::Type{Array{T}}) where T = T

signatureClassFor(name) = length(name) == 1 ? sigTypes[name].classname : name

isVoid(meth::JMethodInfo) = meth.typeInfo.convertType == Nothing

classtypename(ptr::Ptr{Nothing}) = typeNameFor(getclassname(getclass(ptr)))
classtypename(obj::JavaObject{T}) where T = string(T)

# To access static members, use types or metaclasses
# like this: `JProxy(JavaObject{Symbol("java.lang.Byte")}).TYPE`
# or JProxy(JString).valueOf(1)
JProxy(::JavaMetaClass{C}) where C = JProxy(JavaObject{C})
function JProxy(::Type{JavaObject{C}}) where C
    c = Symbol(legalClassName(string(C)))
    obj = classforname(string(c))
    info = infoFor(obj)
    JProxy{typeFor(c), c}(obj, info, true)
end
# Proxies on classes are on the class objects, they don't get you static members
# To access static members, use types or metaclasses
# like this: `JProxy(JavaObject{Symbol("java.lang.Byte")}).TYPE`
JProxy(s::AbstractString) = JProxy(JString(s))
function JProxy{T, C}(ptr::PtrBox) where {T, C}
    JProxy{T, C}(ptr, infoFor(JClass(getclass(ptr))), false)
end
JProxy(obj::JavaObject) = JProxy(PtrBox(obj))
JProxy(ptr::Ptr{Nothing}) = JProxy(PtrBox(ptr))
function JProxy(obj::PtrBox)
    if obj.ptr == C_NULL
        cls = objectClass
        n = "java.lang.Object"
    else
        cls = JClass(getclass(obj.ptr))
        n = legalClassName(getname(cls))
    end
    c = Symbol(n)
    verbose("JPROXY INFO FOR ", n, ", ", getname(cls))
    info = infoFor(cls)
    aType, dim = arrayinfo(n)
    if dim != 0
        typeFor(Symbol(aType))
    end
    JProxy{info.classtype, c}(obj, info, false)
end

function JavaTypeInfo(setterFunc, class, signature, juliaType, convertType, accessorName, boxType, getter, staticGetter, setter, staticSetter)
    boxClass = classfortype(boxType)
    primitive = length(signature) == 1
    primClass = primitive ? jfield(boxType, "TYPE", JClass) : objectClass
    info = JavaTypeInfo(setterFunc, class, signature, juliaType, convertType, primitive, accessorName, boxType, boxClass, primClass, getter, staticGetter, setter, staticSetter)
    info
end

function JFieldInfo(field::JField)
    fcl = jcall(field, "getType", JClass, ())
    typ = juliaTypeFor(legalClassName(fcl))
    static = isStatic(field)
    cls = jcall(field, "getDeclaringClass", JClass, ())
    id = fieldId(getname(field), JavaObject{Symbol(legalClassName(fcl))}, static, field, cls)
    info = get(typeInfo, legalClassName(fcl), genericFieldInfo)
    JFieldInfo{info.convertType}(field, info, static, id, cls)
end

function Boxing(info)
    boxer = methodInfo(getConstructor(info.boxType, info.primClass)).id
    unboxer = methodInfo(getMethod(info.boxType, info.accessorName)).id
    Boxing(info, info.boxType, info.boxClass, types[Symbol(getname(info.boxClass))], info.primClass, boxer, unboxer)
end

gettypeinfo(class::Symbol) = gettypeinfo(string(class))
gettypeinfo(class::AbstractString) = get(typeInfo, class, genericFieldInfo)

hasClass(name::AbstractString) = hasClass(Symbol(name))
hasClass(name::Symbol) = name in genned
hasClass(gen, name::AbstractString) = hasClass(gen, Symbol(name))
hasClass(gen, name::Symbol) = name in genned || haskey(gen.methodDicts, string(name))

function genTypeDecl(name::AbstractString, supername::Symbol, gen)
    if string(name) != "String" && !haskey(types, Symbol(name)) && !haskey(gen.methodDicts, name)
        typeName = typeNameFor(name)
        push!(gen.typeCode, :(abstract type $typeName <: $supername end))
    end
end

function registerclass(name::AbstractString, classType::Type)
    registerclass(Symbol(name), classType)
end
function registerclass(name::Symbol, classType::Type)
    if !(classType <: Union{Array, String}) && !haskey(types, name)
        types[name] = classType
    end
    infoFor(classforname(string(name)))
end

gen(name::Symbol; genmode=:none, print=false, eval=true) = _gen(classforname(string(name)), genmode, print, eval)
gen(name::AbstractString; genmode=:none, print=false, eval=true) = _gen(classforname(name), genmode, print, eval)
gen(pxy::JProxy{T, C}) where {T, C} = gen(C)
gen(class::JClass; genmode=:none, print=false, eval=true) = _gen(class, genmode, eval)
function _gen(class::JClass, genmode, print, evalResult)
    n = legalClassName(class)
    gen = GenInfo()
    genClass(class, gen)
    if genmode == :deep
        while !isempty(gen.deps)
            cls = pop!(gen.deps)
            !hasClass(gen, cls) && genClass(classforname(string(cls)), gen)
        end
    else
        while !isempty(gen.deps)
            cls = pop!(gen.deps)
            !hasClass(gen, cls) && genType(classforname(string(cls)), gen)
        end
    end
    expr = :(begin $(gen.typeCode...); $(gen.code...); $(genClasses(getname.(gen.classList))...); end)
    if print
        for e in expr.args
            println(e)
        end
    end
    evalResult && eval(expr)
end

function genType(class, gen::GenInfo)
    name = getname(class)
    sc = superclass(class)
    push!(genned, Symbol(legalClassName(class)))
    if !isNull(sc)
        if !(Symbol(legalClassName(sc)) in genned)
            genType(getcomponentclass(sc), gen)
        end
        supertype = typeNameFor(sc)
        cType = componentType(supertype)
        genTypeDecl(name, cType, gen)
    else
        genTypeDecl(name, :java_lang, gen)
    end
end

genClass(class::JClass, gen::GenInfo) = genClass(class, gen, infoFor(class))
function genClass(class::JClass, gen::GenInfo, info::JClassInfo)
    name = getname(class)
    if !(Symbol(name) in genned)
        gen.fielddicts[legalClassName(class)] = fielddict(class)
        push!(gen.classList, class)
        sc = superclass(class)
        #verbose("SUPERCLASS OF $name is $(isNull(sc) ? "" : "not ")null")
        push!(genned, Symbol(legalClassName(class)))
        if !isNull(sc)
            supertype = typeNameFor(sc)
            cType = componentType(supertype)
            !hasClass(gen, cType) && genClass(sc, gen)
            genTypeDecl(name, cType, gen)
        else
            genTypeDecl(name, :java_lang, gen)
        end
        genMethods(class, gen, info)
    end
end

GenInfo() = GenInfo([], [], Set(), [], Dict(), Dict())

function GenArgInfo(index, info::JMethodInfo, gen::GenInfo)
    javaType = info.argTypes[index]
    GenArgInfo(Symbol("a" * string(index)), javaType, argType(javaType, gen), argSpec(javaType, gen))
end

argType(t, gen) = t
argType(::Type{JavaObject{Symbol("java.lang.String")}}, gen) = String
argType(::Type{JavaObject{Symbol("java.lang.Object")}}, gen) = :JLegalArg
argType(::Type{<: Number}, gen) = Number
argType(typ::Type{JavaObject{T}}, gen) where T = :(JProxy{<:$(typeNameFor(T, gen)), T})

argSpec(t, gen) = t
argSpec(::Type{JavaObject{Symbol("java.lang.String")}}, gen) = String
argSpec(::Type{JavaObject{Symbol("java.lang.Object")}}, gen) = :JObject
argSpec(::Type{<: Number}, gen) = Number
argSpec(typ::Type{JavaObject{T}}, gen) where T = :(JProxy{<:$(typeNameFor(T, gen)), T})
argSpec(arg::GenArgInfo) = arg.spec

legalClassName(pxy::JProxy) = legalClassName(getclassname(pxystatic(pxy) ? pxyptr(pxy) : getclass(pxyptr(pxy))))
legalClassName(cls::JavaObject) = legalClassName(getname(cls))
legalClassName(cls::Symbol) = legalClassName(string(cls))
function legalClassName(name::AbstractString)
    if (m = match(r"^([^[]*)((\[])+)$", name)) != nothing
        dimensions = Integer(length(m.captures[2]) / 2)
        info = get(typeInfo, m.captures[1], nothing)
        base = if info != nothing && info.primitive
            info.signature
        else
            "L$(m.captures[1]);"
        end
        "$(repeat('[', dimensions))$base"
    else
        name
    end
end

componentType(e::Expr) = e.args[2]
componentType(sym::Symbol) = sym

"""
    typeNameFor(thing)

Attempt to return the type for thing, otherwise return a symbol
representing the type, should it come to exist
"""
typeNameFor(T::Symbol, gen::GenInfo) = typeNameFor(string(T), gen)
function typeNameFor(T::AbstractString, gen::GenInfo)
    aType, dims = arrayinfo(T)
    c = dims != 0 ? aType : T
    csym = Symbol(c)
    if (dims == 0 || length(c) > 1) && !(csym in gen.deps) && !hasClass(gen, csym) && !get(typeInfo, c, genericFieldInfo).primitive
        push!(gen.deps, csym)
    end
    typeNameFor(T)
end
typeNameFor(t::Type) = t
typeNameFor(::Type{JavaObject{T}}) where T = typeNameFor(string(T))
typeNameFor(class::JClass) = typeNameFor(legalClassName(class))
typeNameFor(className::Symbol) = typeNameFor(string(className))
function typeNameFor(className::AbstractString)
    if className == "java.lang.String"
        String
    elseif length(className) == 1
        sigTypes[className].convertType
    else
        n = replace(className, "_" => "___")
        n = replace(className, "\$" => "_s_")
        n = replace(n, "." => "_")
        aType, dims = arrayinfo(n)
        if dims != 0
            Array{typeNameFor(aType), dims}
        else
            t = get(typeInfo, n, genericFieldInfo)
            if t.primitive
                t.juliaType
            else
                sn = Symbol(n)
                get(types, sn, sn)
            end
        end
    end
end

macro jp(s)
    :(JProxy{$(s), Symbol($(classnamefor(s)))})
end

function argCode(arg::GenArgInfo)
    argname = arg.name
    if arg.juliaType == String
        argname
    elseif arg.juliaType == JLegalArg
        :(box($argname))
    elseif arg.juliaType == Number
        :($(arg.javaType)($argname))
    else
        argname
    end
end

function fieldEntry((name, fld))
    fieldType = JavaObject{Symbol(legalClassName(fld.owner))}
    name => :(jfield($(fld.typeInfo.class), $(string(name)), $fieldType))
end

function genMethods(class, gen, info)
    methodList = listmethods(class)
    classname = legalClassName(class)
    gen.methodDicts[classname] = methods = Dict()
    typeName = typeNameFor(classname, gen)
    classVar = Symbol("class_" * string(typeName))
    fieldsVar = Symbol("fields_" * string(typeName))
    methodsVar = Symbol("staticMethods_" * string(typeName))
    push!(gen.code, :($classVar = classforname($classname)))
    push!(gen.code, :($fieldsVar = Dict([$([fieldEntry(f) for f in gen.fielddicts[classname]]...)])))
    push!(gen.code, :($methodsVar = Set($([string(n) for (n, m) in info.methods if any(x->x.static, m)]))))
    push!(gen.code, :(function Base.getproperty(p::JProxy{T, C}, name::Symbol) where {T <: $typeName, C}
                      if (f = get($fieldsVar, name, nothing)) != nothing
                              getField(p, name, f)
                          else
                              JMethodProxy(name, $typeName, p, emptyset)
                          end
                      end))
    for nameSym in sort(collect(keys(info.methods)))
        name = string(nameSym)
        multiple = length(info.methods[nameSym]) > 1
        symId = 0
        for minfo in info.methods[nameSym]
            owner = javaType(minfo.owner)
            if isSame(class.ptr, minfo.owner.ptr)
                symId += 1
                args = (GenArgInfo(i, minfo, gen) for i in 1:length(minfo.argTypes))
                argDecs = (:($(arg.name)::$(arg.juliaType)) for arg in args)
                methodIdName = Symbol("method_" * string(typeName) * "__" * name * (multiple ? string(symId) : ""))
                callinfo = jnicalls[minfo.typeInfo.classname]
                push!(gen.code, :($methodIdName = getmethodid($(minfo.static), $classVar, $name, $(legalClassName(minfo.returnClass)), $(legalClassName.(minfo.argClasses)))))
                push!(gen.code, :(function (pxy::JMethodProxy{Symbol($name), <: $typeName})($(argDecs...))::$(genReturnType(minfo, gen))
                                      verbose($("Generated method $name$(multiple ? "(" * string(symId) * ")" : "")"))
                                      $(genConvertResult(minfo.typeInfo.convertType, minfo, :(call(pxy.obj, $methodIdName, $(static ? callinfo.static : callinfo.instance), $(minfo.typeInfo.juliaType), ($(argSpec.(args)...),), $((argCode(arg) for arg in args)...)))))
                                  end))
            end
        end
    end
    push!(gen.code, :(push!(genned, Symbol($(legalClassName(class))))))
end

function genReturnType(methodInfo, gen)
    t = methodInfo.typeInfo.convertType
    if methodInfo.typeInfo.primitive || t <: String || t == Nothing
        t
    else
        :(JProxy{<:$(typeNameFor(methodInfo.returnType, gen))})
    end
end


genConvertResult(toType::Type{Bool}, info, expr) = :($expr != 0)
genConvertResult(toType::Type{String}, info, expr) = :(unsafe_string($expr))
genConvertResult(toType::Type{<:JBoxTypes}, info, expr) = :(unbox($(toType.parameters[1]), $expr))
function genConvertResult(toType, info, expr)
    if isVoid(info) || info.typeInfo.primitive
        expr
    else
        :(asJulia($toType, $expr))
    end
end

isArray(class::JClass) = jcall(class, "isArray", jboolean, ()) != 0

unionize(::Type{T1}, ::Type{T2}) where {T1, T2} = Union{T1, T2}

function definterfacecvt(ct, interfaces)
    if !isempty(interfaces)
        union = reduce(unionize, [i.classtype for i in interfaces])
        if ct <: interface
            union = unionize(ct, union)
        end
        eval(:(interfacehas(::Type{<:$union}, ::Type{$ct}) = true))
    end
end

function JClassInfo(class::JClass)
    n = Symbol(legalClassName(class))
    verbose("INFO FOR $(string(n))")
    sc = superclass(class)
    parentinfo = !isNull(sc) ? _infoFor(sc) : nothing
    interfaces = [_infoFor(cl) for cl in allinterfaces(class)]
    tname = typeNameFor(string(n))
    #verbose("JCLASS INFO FOR ", n)
    jtype = if tname == String
        String
    elseif isa(tname, Type) && tname <: Array
        tname
    else
        get!(types, n) do
            _defjtype(tname, tname == Symbol("java.lang.Object") ? java_lang : isNull(sc) ? interface : typeNameFor(Symbol(legalClassName(sc))))
        end
    end
    definterfacecvt(jtype, interfaces)
    classes[n] = JClassInfo(parentinfo, class, fielddict(class), methoddict(class), jtype)
end

genClasses(classNames) = (:(registerclass($name, $(Symbol(typeNameFor(name))))) for name in reverse(classNames))

typeFor(::Type{JavaObject{T}}) where T = typeFor(T)
function typeFor(sym::Symbol)
    aType, dims = arrayinfo(string(sym))
    dims != 0 ? Array{get(types, Symbol(aType), java_lang), length(dims)} : get(types, sym, java_lang)
end

function makeTypeFor(class::JClass)
    cln = Symbol(getname(class))
    t = typeFor(cln)
    if t == java_lang
        sc = superclass(class)
        sct = isNull(sc) ? java_lang : makeTypeFor(sc)
        _defjtype(typeNameFor(cln), nameof(sct))
    end
    t
end

asJulia(t, obj) = obj
asJulia(::Type{Bool}, obj) = obj != 0
asJulia(t, obj::JBoxed) = unbox(obj)
function asJulia(x, ptr::Ptr{Nothing})
    verbose("ASJULIA: ", repr(ptr))
    if ptr == C_NULL
        nothing
    else
        verbose("UNBOXING ", ptr)
        unbox(JavaObject{Symbol(legalClassName(getclassname(getclass(ptr))))}, ptr)
    end
end

box(str::AbstractString) = str
box(pxy::JProxy) = ptrObj(pxy)

unbox(obj) = obj
unbox(::Type{T}, obj) where T = obj
function unbox(::Type{JavaObject{T}}, obj::Ptr{Nothing}) where T
    if  obj == C_NULL
        nothing
    else
        #verbose("UNBOXING ", T)
        (get(juliaConverters, string(T)) do
            (x)-> JProxy(x)
        end)(obj)
    end
end

pxyptr(p::JProxy) = getfield(p, :ptr)
pxyinfo(p::JProxy) = getfield(p, :info)
pxystatic(p::JProxy) = getfield(p, :static)

==(j1::JProxy, j2::JProxy) = isSame(pxyptr(j1), pxyptr(j2))

isSame(j1::JavaObject, j2::JavaObject) = isSame(j1.ptr, j2.ptr)
isSame(j1::Ptr{Nothing}, j2::Ptr{Nothing}) = @jnicall(jnifunc.IsSameObject, Ptr{Nothing}, (Ptr{Nothing}, Ptr{Nothing}), j1, j2) != C_NULL

getreturntype(c::JConstructor) = voidClass

function getMethod(class::Type, name::AbstractString, argTypes...)
    jcall(classfortype(class), "getMethod", JMethod, (JString, Vector{JClass}), name, collect(JClass, argTypes))
end

function getConstructor(class::Type, argTypes...)
    jcall(classfortype(class), "getConstructor", JConstructor, (Vector{JClass},), collect(argTypes))
end

getConstructors(class::Type) = jcall(classfortype(class), "getConstructors", Array{JConstructor}, ())

function argtypefor(class::JClass)
    cln = getclassname(class.ptr)
    tinfo = gettypeinfo(cln)
    if tinfo.primitive
        tinfo.convertType
    elseif cln == "java.lang.String"
        String
    else
        sn = Symbol(cln)
        makeTypeFor(class)
        typeFor(sn)
    end
end

methodInfo(class::AbstractString, name::AbstractString, argTypeNames::Array) = methodCache[(class, name, argTypeNames)]
function methodInfo(m::Union{JMethod, JConstructor})
    name, returnType, argTypes = getname(m), getreturntype(m), getparametertypes(m)
    cls = jcall(m, "getDeclaringClass", JClass, ())
    methodKey = (legalClassName(cls), name, legalClassName.(argTypes))
    get!(methodCache, methodKey) do
        methodId = getmethodid(isStatic(m), legalClassName(cls), name, legalClassName(returnType), legalClassName.(argTypes))
        typeName = legalClassName(returnType)
        info = get(typeInfo, typeName, genericFieldInfo)
        owner = metaclass(legalClassName(cls))
        methodsById[length(methodsById)] = JMethodInfo(name, info, Symbol(typeName), returnType, Tuple(argtypefor.(argTypes)), argTypes, methodId, isStatic(m), owner, get(jnicalls, typeName, Tuple(filterDynArgType.(juliaTypeFor.(argTypes)))))
    end
end

filterDynArgType(::Type{<:AbstractString}) = JavaObject{Symbol("java.lang.String")}
filterDynArgType(t) = t

isStatic(meth::JConstructor) = false
function isStatic(meth::Union{JMethod,JField})
    global modifiers

    mods = jcall(meth, "getModifiers", jint, ())
    jcall(modifiers, "isStatic", jboolean, (jint,), mods) != 0
end

conv(func::Function, typ::AbstractString) = juliaConverters[typ] = func

macro typeInf(jclass, sig, jtyp, jBoxType)
    _typeInf(jclass, Symbol("j" * string(jclass)), sig, jtyp, uppercasefirst(string(jclass)), false, string(jclass) * "Value", "java.lang." * string(jBoxType))
end

macro vtypeInf(jclass, ctyp, sig, jtyp, Typ, object, jBoxType)
    if typeof(jclass) == String
        jclass = Symbol(jclass)
    end
    _typeInf(jclass, ctyp, sig, jtyp, Typ, object, "", "java.lang." * string(jBoxType))
end

sym(s) = :(Symbol($(string(s))))

function _typeInf(jclass, ctyp, sig, jtyp, Typ, object, accessor, boxType)
    s = (p, t)-> :(jnifunc.$(Symbol(p * string(t) * "Field")))
    quote
        begin
            JavaTypeInfo($(sym(jclass)), $sig, $ctyp, $jtyp, $accessor, JavaObject{Symbol($boxType)}, $(s("Get", Typ)), $(s("GetStatic", Typ)), $(s("Set", Typ)), $(s("SetStatic", Typ))) do field, obj, value::$(object ? :JavaObject : ctyp)
                @jnicall(field.static ? field.typeInfo.staticSetter : field.typeInfo.setter, Ptr{Nothing},
                      (Ptr{Nothing}, Ptr{Nothing}, $(object ? :(Ptr{Nothing}) : ctyp)),
                      (field.static ? field.owner.ptr : pxyptr(obj)), field.id, $(object ? :(pxyptr(value)) : :value))
            end
        end
    end
end

macro defbox(primclass, boxtype, juliatype, javatype = juliatype)
    :(eval(_defbox($(sym(primclass)), $(sym(boxtype)), $(sym(juliatype)), $(sym(javatype)))))
end

function _defbox(primclass, boxtype, juliatype, javatype)
    boxclass = JavaObject{Symbol(classnamefor(boxtype))}
    primname = string(primclass)
    boxVar = Symbol(primname * "Box")
    varpart = if juliatype == :Bool
        quote
            convert(::Type{JavaObject{T}}, obj::Union{jboolean, Bool}) where T = JavaObject(box(obj))
            function unbox(::Type{$boxclass}, ptr::Ptr{Nothing})
                  call(ptr, $boxVar.unboxer, jboolean, ()) != 0
            end
            function unbox(::Type{$boxtype}, ptr::Ptr{Nothing})
                call(ptr, $boxVar.unboxer, jboolean, ()) != 0
            end
            function unbox(obj::JavaObject{Symbol($(classnamefor(boxtype)))})
                _jcall(obj, $boxVar.unboxer, C_NULL, jboolean, ()) != 0
            end
        end
    else
        quote
            #convert(::Type{JavaObject{T}}, obj::$juliatype) where T = JavaObject(box(obj))
            $(if juliatype == :jchar
                  :(convert(::Type{JavaObject{T}}, obj::Char) where T = JavaObject(box(obj)))
              else
                  ()
              end)
            function unbox(::Type{$boxclass}, ptr::Ptr{Nothing})
                call(ptr, $boxVar.unboxer, $javatype, ())
            end
            function unbox(::Type{$boxtype}, ptr::Ptr{Nothing})
                call(ptr, $boxVar.unboxer, $javatype, ())
            end
            function unbox(obj::JavaObject{Symbol($(classnamefor(boxtype)))})
                _jcall(obj, $boxVar.unboxer, C_NULL, $juliatype, ())
            end
        end
    end
    quote
        const $boxVar = boxers[$primname] = Boxing(typeInfo[$primname])
        boxer(::Type{$juliatype}) = $boxVar
        function box(data::$juliatype)
            #println("BOXING ", $primname, ", boxvar: ", $(string(boxVar)))
            JProxy(_jcall($boxVar.boxClass, $boxVar.boxer, jnifunc.NewObjectA, $boxclass, ($juliatype,), data))
        end
        $varpart
    end
end

function initProxy()
    push!(jnicalls,
          :boolean => (static=:CallStaticBooleanMethodA, instance=:CallBooleanMethodA),
          :byte => (static=:CallStaticByteMethodA, instance=:CallByteMethodA),
          :char => (static=:CallStaticCharMethodA, instance=:CallCharMethodA),
          :short => (static=:CallStaticShortMethodA, instance=:CallShortMethodA),
          :int => (static=:CallStaticIntMethodA, instance=:CallIntMethodA),
          :long => (static=:CallStaticLongMethodA, instance=:CallLongMethodA),
          :float => (static=:CallStaticFloatMethodA, instance=:CallFloatMethodA),
          :double => (static=:CallStaticDoubleMethodA, instance=:CallDoubleMethodA),
          :Nothing => (static=:CallStaticVoidMethodA, instance=:CallVoidMethodA),
    )
    global objectClass = classforname("java.lang.Object")
    global classClass = classforname("java.lang.Class")
    global voidClass = jfield(JavaObject{Symbol("java.lang.Void")}, "TYPE", JClass)
    global methodid_getmethod = getmethodid("java.lang.Class", "getMethod", "java.lang.reflect.Method", "java.lang.String", "[Ljava.lang.Class;")
    conv("java.lang.String") do x; unsafe_string(x); end
    conv("java.lang.Integer") do x; @jp(java_lang_Integer)(x).intValue(); end
    conv("java.lang.Long") do x; @jp(java_lang_Long)(x).longValue(); end
    push!(typeInfo,
        "void" => @vtypeInf(void, jint, "V", Nothing, Object, false, Void),
        "boolean" => @typeInf(boolean, "Z", Bool, Boolean),
        "byte" => @typeInf(byte, "B", Int8, Byte),
        "char" => @typeInf(char, "C", Char, Character),
        "short" => @typeInf(short, "S", Int16, Short),
        "int" => @typeInf(int, "I", Int32, Integer),
        "float" => @typeInf(float, "F", Float32, Float),
        "long" => @typeInf(long, "J", Int64, Long),
        "double" => @typeInf(double, "D", Float64, Double),
        "java.lang.String" => @vtypeInf("java.lang.String", String, "Ljava/lang/String;", String, Object, true, Object),
    )
    global sigTypes = Dict([inf.signature => inf for (key, inf) in typeInfo if inf.primitive])
    global genericFieldInfo = @vtypeInf("java.lang.Object", Any, "Ljava/lang/Object;", JObject, Object, true, Object)
    global methodId_object_getClass = getmethodid("java.lang.Object", "getClass", "java.lang.Class")
    global methodId_class_getName = getmethodid("java.lang.Class", "getName", "java.lang.String")
    global methodId_class_getInterfaces = getmethodid("java.lang.Class", "getInterfaces", "[Ljava.lang.Class;")
    global methodId_class_isInterface = getmethodid("java.lang.Class", "isInterface", "boolean")
    global methodId_system_gc = getmethodid(true, "java.lang.System", "gc", "void", String[])
    global initialized = true
    @defbox(boolean, java_lang_Boolean, Bool, jboolean)
    @defbox(char, java_lang_Character, Char, jchar)
    @defbox(byte, java_lang_Byte, jbyte)
    @defbox(short, java_lang_Short, jshort)
    @defbox(int, java_lang_Integer, jint)
    @defbox(long, java_lang_Long, jlong)
    @defbox(float, java_lang_Float, jfloat)
    @defbox(double, java_lang_Double, jdouble)
end

metaclass(class::AbstractString) = metaclass(Symbol(class))

function getclass(obj::Ptr{Nothing})
    initialized ? @message(obj, Ptr{Nothing}, methodId_object_getClass) : C_NULL
end

function getclassname(class::Ptr{Nothing})
    initialized ? unsafe_string(@message(class, Ptr{Nothing}, methodId_class_getName)) : "UNKNOWN"
end

isinterface(class::Ptr{Nothing}) = @message(class, jboolean, methodId_class_isInterface) != 0

function getinterfaces(class::JClass)
    array = @message(class.ptr, Ptr{Nothing}, methodId_class_getInterfaces)
    [JClass(arrayat(array, i)) for i in 1:arraylength(array)]
end

jarray(array::Ptr{Nothing}) = [arrayat(array, i) for i in 1:arraylength(array)]

function allinterfaces(class::JClass)
    result = []
    queue = [class]
    seen = Set()
    while !isempty(queue)
        for interface in getinterfaces(pop!(queue))
            if !(interface in seen)
                push!(seen, interface)
                push!(result, interface)
                push!(queue, interface)
            end
        end
    end
    reverse(result)
end

function getmethodid(cls::AbstractString, name, rettype::AbstractString, argtypes::AbstractString...)
    getmethodid(false, cls, name, rettype, collect(argtypes))
end
function getmethodid(static, cls::JClass, name, rettype::AbstractString, argtypes::Vector{<:AbstractString})
    getmethodid(static, cls, name, classforlegalname(rettype), collect(JClass, classforlegalname.(argtypes)))
end
getmethodid(static, cls::JClass, name, rettype, argtypes) = getmethodid(static, legalClassName(cls), name, rettype, argtypes)
function getmethodid(static::Bool, clsname::AbstractString, name::AbstractString, rettype::AbstractString, argtypes::Vector{<:Union{JClass, AbstractString}})
    sig = proxyMethodSignature(rettype, argtypes)
    jclass = metaclass(clsname)
    #verbose(@macroexpand @jnicall(static ? jnifunc.GetStaticMethodID : jnifunc.GetMethodID, Ptr{Nothing},
    #        (Ptr{Nothing}, Ptr{UInt8}, Ptr{UInt8}),
    #        jclass, name, sig))
    @jnicall(static ? jnifunc.GetStaticMethodID : jnifunc.GetMethodID, Ptr{Nothing},
            (Ptr{Nothing}, Ptr{UInt8}, Ptr{UInt8}),
            jclass, name, sig)
end

function fieldId(name, typ::Type{JavaObject{C}}, static, field, cls::JClass) where {C}
    @jnicall(static ? jnifunc.GetStaticFieldID : jnifunc.GetFieldID, Ptr{Nothing},
            (Ptr{Nothing}, Ptr{UInt8}, Ptr{UInt8}),
            metaclass(legalClassName(cls)), name, proxyClassSignature(string(C)))
end

function infoSignature(cls::AbstractString)
    info = get(typeInfo, cls, nothing)
    if info != nothing; info.signature; end
end

proxyClassSignature(cls::JClass) = proxyClassSignature(legalClassName(cls))
function proxyClassSignature(clsname::AbstractString)
    info = get(typeInfo, clsname, nothing)
    if info != nothing && info.primitive
        info.signature
    else
        atype, dim = arrayinfo(clsname)
        dim > 0 ? javaclassname(clsname) : "L" * javaclassname(clsname) * ";"
    end
end

function getcomponentclass(class::JClass)
    while jcall(class, "isArray", jboolean, ()) != 0
        class = jcall(class, "getComponentType", JClass, ())
    end
    class
end

function proxyMethodSignature(rettype, argtypes)
    s = IOBuffer()
    write(s, "(")
    for arg in argtypes
        write(s, proxyClassSignature(arg))
    end
    write(s, ")")
    write(s, proxyClassSignature(rettype))
    String(take!(s))
end

juliaTypeFor(class::JavaObject) = juliaTypeFor(legalClassName(class))
function juliaTypeFor(name::AbstractString)
    info = get(typeInfo, name, nothing)
    info != nothing ? info.juliaType : JavaObject{Symbol(name)}
end

function infoFor(class::JClass)
    result = _infoFor(class)
    deletelocals()
    result
end
function _infoFor(class::JClass)
    if isNull(class)
        nothing
    else
        name = legalClassName(class)
        #verbose("INFO FOR ", name)
        haskey(classes, name) ? classes[name] : classes[name] = JClassInfo(class)
    end
end

getname(thing::Union{JClass, JMethod, JField}) = jcall(thing, "getName", JString, ())
getname(thing::JConstructor) = "<init>"

function classforlegalname(n::AbstractString)
    try
        (i = get(typeInfo, n, nothing)) != nothing && i.primitive ? i.primClass : classforname(n)
    catch x
        #verbose("Error finding class: $n, type: $(typeof(n))")
        throw(x)
    end
end

classfortype(t::Type{JavaObject{T}}) where T = classforname(string(T))
classfortype(t::Type{T}) where {T <: java_lang} = classforname(classnamefor(nameof(T)))

listfields(cls::AbstractString) = listfields(classforname(cls))
listfields(cls::Type{JavaObject{C}}) where C = listfields(classforname(string(C)))
listfields(cls::JClass) = jcall(cls, "getFields", Vector{JField}, ())

function fielddict(class::JClass)
    if isArray(class)
        Dict([:length => JReadonlyField((obj)->arraylength(obj.ptr))])
    else
        Dict([Symbol(getname(item)) => JFieldInfo(item) for item in listfields(class)])
    end
end

arraylength(obj::JavaObject) = arraylength(obj.ptr)
arraylength(obj) = @jnicall(jnifunc.GetArrayLength, jint, (Ptr{Nothing},), obj)

arrayat(obj::JavaObject, i) = arrayat(obj.ptr, i)
arrayat(obj, i) = @jnicall(jnifunc.GetObjectArrayElement, Ptr{Nothing},
                           (Ptr{Nothing}, jint),
                           obj, jint(i) - 1)

Base.length(obj::JavaObject) = Base.length(JProxy(obj))
Base.length(pxy::JProxy{>:Array}) = arraylength(pxyptr(pxy))

function Base.getindex(pxy::JProxy{>:Array}, i::Integer)
    asJulia(T, @jnicall(jnifunc.GetObjectArrayElement, Ptr{Nothing},
                          (Ptr{Nothing}, jint),
                          pxyptr(pxy), jint(i) - 1))
end

function methoddict(class)
    d = Dict()
    for method in listmethods(class)
        s = get!(d, Symbol(getname(method))) do
            Set()
        end
        push!(s, methodInfo(method))
    end
    d
end

javaType(::JavaObject{T}) where T = T
javaType(::Type{JavaObject{T}}) where T = T
javaType(::JavaMetaClass{T}) where T = T

isNull(obj::JavaObject) = isNull(obj.ptr)
isNull(ptr::Ptr{Nothing}) = Int64(ptr) == 0

superclass(obj::JavaObject) = jcall(obj, "getSuperclass", @jimport(java.lang.Class), ())

function getField(p::JProxy, field::JFieldInfo)
    asJulia(field.typeInfo.juliaType, @jnicall(static ? field.typeInfo.staticGetter : field.typeInfo.getter, Ptr{Nothing},
                                           (Ptr{Nothing}, Ptr{Nothing}),
                                           pxystatic(p) ? getclass(obj) : pxyptr(p), field.id))
end

function Base.getproperty(p::JProxy{T}, name::Symbol) where T
    info = pxyinfo(p)
    if haskey(info.methods, name)
        m = pxystatic(p) ? filter(m->m.static, info.methods[name]) : info.methods[name]
        isempty(m) && throw(KeyError("key: $name not found"))
        JMethodProxy(name, T, p, m)
    else
        getproxyfield(p, info.fields[name])
    end
end

getter(field::JFieldInfo) = field.static ? field.typeInfo.staticGetter : field.typeInfo.getter

setter(field::JFieldInfo) = field.static ? field.typeInfo.staticSetter : field.typeInfo.setter

getproxyfield(p::JProxy, field::JReadonlyField) = field.get(pxyptr(p))
function getproxyfield(p::JProxy, field::JFieldInfo)
    static = pxystatic(p)
    ptr = field.static ? C_NULL : pxyptr(p)
    result = _getproxyfield(ptr, field)
    geterror()
    verbose("FIELD CONVERT RESULT ", repr(result), " TO ", field.typeInfo.convertType)
    asJulia(field.typeInfo.convertType, result)
end
macro defgetfield(juliat, javat = juliat)
    :(function _getproxyfield(p::Ptr{Nothing}, field::JFieldInfo{$juliat})
            local result = ccall(getter(field), $javat,
                                 (Ptr{JNIEnv}, Ptr{Nothing}, Ptr{Nothing}),
                                 penv, p, field.id)
            result == C_NULL && geterror()
            result
        end)
end
@defgetfield(<:Any, Ptr{Nothing})
@defgetfield(Bool, jboolean)
@defgetfield(jbyte)
@defgetfield(jchar)
@defgetfield(jshort)
@defgetfield(jint)
@defgetfield(jlong)
@defgetfield(jfloat)
@defgetfield(jdouble)

function setproxyfield(p::JProxy, field::JFieldInfo{T}, value) where T
    primsetproxyfield(p, field, convert(T, value))
end
setproxyfield(p::JProxy, field::JFieldInfo, value::JProxy) = primsetproxyfield(p, field, pxyptr(value))
setproxyfield(p::JProxy, field::JFieldInfo, value::JavaObject) = primsetproxyfield(p, field, value.ptr)
function setproxyfield(p::JProxy, field::JFieldInfo{String}, value::AbstractString)
    str = JString(convert(String, value))
    primsetproxyfield(p, field, str.ptr)
end
function primsetproxyfield(p::JProxy, field::JFieldInfo, value)
    result = _setproxyfield(pxystatic(p) ? C_NULL : pxyptr(p), field, value)
    geterror()
    verbose("FIELD CONVERT RESULT ", repr(result), " TO ", field.typeInfo.convertType)
    asJulia(field.typeInfo.convertType, result)
end
function _setproxyfield(p::Ptr{Nothing}, field::JFieldInfo{JavaObject{T}}, value::Ptr{Nothing}) where T
    @jnicall(setter(field), Nothing,
             (Ptr{Nothing}, Ptr{Nothing}, Ptr{Nothing}),
             p, field.id, value)
end
macro defsetfield(juliat, javat = juliat)
    :(function _setproxyfield(p::Ptr{Nothing}, field::JFieldInfo{$juliat}, value::$javat)
            local result = ccall(setter(field), Nothing,
                                 (Ptr{JNIEnv}, Ptr{Nothing}, Ptr{Nothing}, $javat),
                                 penv, p, field.id, value)
            result == C_NULL && geterror()
            result
        end)
end
@defsetfield(String, Ptr{Nothing})
@defsetfield(Bool, jboolean)
@defsetfield(jbyte)
@defsetfield(jchar)
@defsetfield(jshort)
@defsetfield(jint)
@defsetfield(jlong)
@defsetfield(jfloat)
@defsetfield(jdouble)

function Base.setproperty!(p::JProxy, name::Symbol, value)
    info = pxyinfo(p)
    meths = get(info.methods, name, nothing)
    static = pxystatic(p)
    result = if meths != nothing
        throw(JavaCallError("Attempt to set a method"))
    else
        setproxyfield(p, info.fields[name], value)
        value
    end
    isa(result, JavaObject) ? JProxy(result) : result
end

function (pxy::JMethodProxy{N})(args...) where N
    targets = Set(m for m in filterStatic(pxy, pxy.methods) if fits(m, args))
    #verbose("LOCATING MESSAGE ", N, " FOR ARGS ", repr(args))
    if !isempty(targets)
        # Find the most specific method
        argTypes = typeof(args).parameters
        meth = reduce(((x, y)-> specificity(argTypes, x) > specificity(argTypes, y) ? x : y), targets)
        verbose("SEND MESSAGE ", N, " RETURNING ", meth.typeInfo.juliaType, " ARG TYPES ", meth.argTypes)
        if meth.static
            staticcall(meth.id, meth.typeInfo.convertType, meth.dynArgTypes, args...)
        else
            #call(pxy.obj, meth.id, meth.typeInfo.convertType, meth.dynArgTypes, args...)
            #println("argTypes: ", meth.argTypes)
            call(pxy.obj, meth.id, meth.typeInfo.convertType, meth.argTypes, args...)
        end
    else
        throw(ArgumentError("No $N method for argument types $(typeof.(args))"))
    end
end

function findmethod(pxy::JMethodProxy, args...)
    targets = Set(m for m in filterStatic(pxy, pxy.methods) if fits(m, args))
    if !isempty(targets)
        argTypes = typeof(args).parameters
        reduce(((x, y)-> specificity(argTypes, x) > specificity(argTypes, y) ? x : y), targets)
    end
end

withlocalref(func, result::Any) = func(result)
function withlocalref(func, ptr::Ptr{Nothing})
    ref = ccall(jnifunc.NewLocalRef, Ptr{Nothing}, (Ptr{JNIEnv}, Ptr{Nothing}), penv, ptr)
    try
        func(ref)
    finally
        deletelocalref(ptr::Ptr{Nothing}) = ccall(jnifunc.DeleteLocalRef, Nothing, (Ptr{JNIEnv}, Ptr{Nothing}), penv, ref)
    end
end

function filterStatic(pxy::JMethodProxy, targets)
    static = pxy.static
    Set(target for target in targets if target.static == static)
end

#fits(method::JMethodInfo, args::Tuple) = length(method.dynArgTypes) == length(args) && all(canConvert.(method.dynArgTypes, args))
fits(method::JMethodInfo, args::Tuple) = length(method.dynArgTypes) == length(args) && all(canConvert.(method.argTypes, args))

canConvert(::Type{T}, ::T) where T = true
canConvert(t::Type, ::T) where T = canConvertType(t, T)
canConvert(::Type{Array{T1,D}}, ::Array{T2,D}) where {T1, T2, D} = canConvertType(T1, T2)
canConvert(::Type{T1}, ::JProxy{T2}) where {T1, T2} = canConvertType(T1, T2)

canConvertType(::Type{T}, ::Type{T}) where T = true
canConvertType(::Type{T1}, t::Type{T2}) where {T1 <: java_lang_Object, T2 <: java_lang_Object} = T2 <: T1
canConvertType(::Type{<:Union{JavaObject{Symbol("java.lang.Object")}, java_lang_Object}}, ::Type{<:Union{AbstractString, JPrimitive}}) = true
canConvertType(::Type{<:Union{JavaObject{Symbol("java.lang.Double")}, java_lang_Double}}, ::Type{<:Union{Float64, Float32, Float16, Int64, Int32, Int16, Int8}}) = true
canConvertType(::Type{<:Union{JavaObject{Symbol("java.lang.Float")}, java_lang_Float}}, ::Type{<:Union{Float32, Float16, Int32, Int16, Int8}}) = true
canConvertType(::Type{<:Union{JavaObject{Symbol("java.lang.Long")}, java_lang_Long}}, ::Type{<:Union{Int64, Int32, Int16, Int8}}) = true
canConvertType(::Type{<:Union{JavaObject{Symbol("java.lang.Integer")}, java_lang_Integer}}, ::Type{<:Union{Int32, Int16, Int8}}) = true
canConvertType(::Type{<:Union{JavaObject{Symbol("java.lang.Short")}, java_lang_Short}}, ::Type{<:Union{Int16, Int8}}) = true
canConvertType(::Type{<:Union{JavaObject{Symbol("java.lang.Byte")}, java_lang_Byte}}, ::Type{Int8}) = true
canConvertType(::Type{<:Union{JavaObject{Symbol("java.lang.Character")}, java_lang_Character}}, ::Type{<:Union{Int8, Char}}) = true
canConvertType(::Type{<:AbstractString}, ::Type{<:AbstractString}) = true
canConvertType(::Type{JString}, ::Type{<:AbstractString}) = true
canConvertType(::Type{<: Real}, ::Type{<:Real}) = true
canConvertType(::Type{jboolean}, ::Type{Bool}) = true
canConvertType(::Type{jchar}, ::Type{Char}) = true
canConvertType(x, y) = interfacehas(x, y)

interfacehas(x, y) = false

# ARG MUST BE CONVERTABLE IN ORDER TO USE CONVERT_ARG
function convert_arg(t::Type{<:Union{JObject, java_lang_Object}}, x::JPrimitive)
    #result = JavaObject(box(x))
    #convert_arg(typeof(result), result)
    result = box(x)
    result, pxyptr(result)
end
convert_arg(t::Type{JavaObject}, x::JProxy) = convert_arg(t, JavaObject(x))
convert_arg(::Type{T1}, x::JProxy) where {T1 <: java_lang} = x, pxyptr(x)
convert_arg(::Type{T}, x) where {T <: java_lang} = convert_arg(JavaObject{Symbol(classnamefor(T))}, x)

# score specificity of a method
function specificity(argTypes, mi::JMethodInfo) where T
    g = 0
    for i in 1:length(argTypes)
        g += specificity(argTypes[i], mi.argTypes[i])
    end
    g
end

isPrimitive(cls::JavaObject) = jcall(cls, "isPrimitive", jboolean, ()) != 0

const specificityworst = -1000000
const specificitybest = 1000000
const specificitybox = 100000
const specificityinherit = 10000

# score relative generality of corresponding arguments in two methods
# higher means c1 is more general than c2 (i.e. c2 is the more specific one)
specificity(::Type{JProxy{T}}, t1) where T = specificity(T, t1)
specificity(argType::Type{<:Union{JBoxTypes,JPrimitive}}, t1::Type{<:JPrimitive}) = specificitybest
specificity(argType::Type{<:JBoxTypes}, t1::Type{<:JBoxTypes}) = specificitybest
specificity(argType::Type{<:JPrimitive}, t1::Type{<:JBoxTypes}) = specificitybox
function specificity(argType::Type, t1::Type)
    if argType == t1 || interfacehas(t1, argType)
        specificitybest
    elseif argType <: t1
        at = argType
        spec = specificityinherit
        while at != t1
            spec -= 1
            at = supertype(at)
        end
        spec
    else
        specificityworst
    end
end

function call(ptr::Ptr{Nothing}, mId::Ptr{Nothing}, rettype::Type{T}, argtypes::Tuple, args...) where T
    ptr == C_NULL && error("Attempt to call method on Java NULL")
    savedargs, convertedargs = convert_args(argtypes, args...)
    for i in 1:length(argtypes)
        if isa(savedargs[i], JavaObject) && convertedargs[i] != 0
            aptr = Ptr{Nothing}(convertedargs[i])
            if getreftype(aptr) == 1
                #println("LOCAL REF")
                push!(allocatedrefs, aptr)
            end
            #println("class: ", getclassname(getclass(aptr)), " type: ", argtypes[i], " arg: ", args[i], " saved: ", savedargs[i], " REFTYPE: ", getreftype(aptr))
        end
    end
    verbose("CALL METHOD RETURNING $rettype WITH ARG TYPES $(argtypes): ACTUAL TYPES $(join(types, ", "))")
    result = _call(T, ptr, mId, convertedargs)
    if rettype <: JavaObject && result != C_NULL
        #println("RESULT REF TYPE: ", getreftype(result))
        push!(allocatedrefs, result)
    end
    result == C_NULL && geterror()
    result = asJulia(rettype, result)
    deletelocals()
    result
end

macro defcall(t, f, ft)
    :(_call(::Type{$t}, obj, mId, args) = ccall(jnifunc.$(Symbol("Call" * string(f) * "MethodA")), $ft,
                                               (Ptr{JNIEnv}, Ptr{Nothing}, Ptr{Nothing}, Ptr{Nothing}),
                                               penv, obj, mId, args))
end

_call(::Type, obj, mId, args) = ccall(jnifunc.CallObjectMethodA, Ptr{Nothing},
  (Ptr{JNIEnv}, Ptr{Nothing}, Ptr{Nothing}, Ptr{Nothing}),
  penv, obj, mId, args)
@defcall(Bool, Boolean, jboolean)
@defcall(jbyte, Byte, jbyte)
@defcall(jchar, Char, jchar)
@defcall(jshort, Short, jshort)
@defcall(jint, Int, jint)
@defcall(jlong, Long, jlong)
@defcall(jfloat, Float, jfloat)
@defcall(jdouble, Double, jdouble)
@defcall(Nothing, Void, Nothing)

function staticcall(mId, rettype::Type{T}, argtypes::Tuple, args...) where T
    savedargs, convertedargs = convert_args(argtypes, args...)
    result = _staticcall(T, mId, convertedargs)
    verbose("CONVERTING RESULT ", repr(result), " TO ", rettype)
    result == C_NULL && geterror()
    verbose("RETTYPE: ", rettype)
    result = asJulia(rettype, result)
    deletelocals()
    result
end

macro defstaticcall(t, f, ft)
    :(_staticcall(::Type{$t}, mId, args) = ccall(jnifunc.$(Symbol("CallStatic" * string(f) * "MethodA")), $ft,
                                                 (Ptr{JNIEnv}, Ptr{Nothing}, Ptr{Nothing}),
                                                 penv, mId, args))
end

_staticcall(::Type, mId, args) = ccall(jnifunc.CallStaticObjectMethodA, Ptr{Nothing},
  (Ptr{JNIEnv}, Ptr{Nothing}, Ptr{Nothing}, Ptr{Nothing}),
  penv, C_NULL, mId, args)
@defstaticcall(Bool, Boolean, jboolean)
@defstaticcall(jbyte, Byte, jbyte)
@defstaticcall(jchar, Char, jchar)
@defstaticcall(jshort, Short, jshort)
@defstaticcall(jint, Int, jint)
@defstaticcall(jlong, Long, jlong)
@defstaticcall(jfloat, Float, jfloat)
@defstaticcall(jdouble, Double, jdouble)
@defstaticcall(Nothing, Void, Nothing)

Base.show(io::IO, pxy::JProxy) = print(io, pxystatic(pxy) ? "static class $(legalClassName(pxy))" : pxy.toString())

JavaObject(pxy::JProxy{T, C}) where {T, C} = JavaObject{C}(pxyptr(pxy))
