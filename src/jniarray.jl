jniname(::Type{jboolean}) = "Boolean"
jniname(::Type{jbyte}) = "Byte"
jniname(::Type{jchar}) = "Char"
jniname(::Type{jshort}) = "Short"
jniname(::Type{jint}) = "Int"
jniname(::Type{jlong}) = "Long"
jniname(::Type{jfloat}) = "Float"
jniname(::Type{jdouble}) = "Double"


mutable struct JNIArray{T} <: AbstractVector{T}
    ref::JavaRef
    arr::Union{Nothing,Vector{T}}
    function JNIArray{T}(ref) where T
        j = new{T}(ref, nothing)
        finalizer(deleteref, j)
        return j
    end
end

Base.getindex(jarr::JNIArray, args...) = getindex(jarr.arr, args...)
Base.setindex!(jarr::JNIArray, args...) = setindex!(jarr.arr, args...)
Base.size(jarr::JNIArray, args...; kwargs...) = size(jarr.arr, args...; kwargs...)

function deleteref(x::JNIArray{T}) where T
    if x.arr !== nothing
        release_elements(x)
    end
    deleteref(x.ref)
    x.ref = J_NULL
end

signature(::Type{JNIArray{T}}) where T = string("[", signature(T))
jvalue(jarr::JNIArray) = jarr.ref.ptr
JNIArray{T}(ptr::Ptr{Nothing}) where {T} = JNIArray{T}(JavaLocalRef(ptr))

function convert(::Type{JNIArray{T}}, vec::Vector{T}) where {T}
    arr = JNIArray{T}(length(vec))
    arr .= vec
    return arr
end

JNIArray(vec::Vector{T}) where {T} = convert(JNIArray{T}, vec)

for primitive in [:jboolean, :jchar, :jbyte, :jshort, :jint, :jlong, :jfloat, :jdouble]
    name = jniname(eval(primitive))
    get_elements = :(JNI.$(Symbol("Get$(name)ArrayElements")))
    release_elements = :(JNI.$(Symbol("Release$(name)ArrayElements")))
    new_array = :(JNI.$(Symbol("New$(name)Array")))
    m = quote
        function get_elements!(jarr::JNIArray{$primitive})
            sz = Int(JNI.GetArrayLength(jarr.ref.ptr))
            jarr.arr = unsafe_wrap(Array, $get_elements(jarr.ref.ptr, Ptr{jboolean}(C_NULL)), sz)
            jarr
        end
        JNIArray{$primitive}(sz::Int) = get_elements!(JNIArray{$primitive}($new_array(sz)))
        function release_elements(arg::JNIArray{$primitive})
            $release_elements(arg.ref.ptr, pointer(arg.arr), jint(0))
            arg.arr = nothing
        end
        function convert_result(::Type{JNIArray{$primitive}}, ptr)
            get_elements!(JNIArray{$primitive}(ptr))
        end
        function convert_arg(argtype::Type{Vector{$primitive}}, arg::JNIArray{$primitive})
            release_elements(arg)
            return arg, arg
        end
        function convert_arg(argtype::Type{JNIArray{$primitive}}, arg::JNIArray{$primitive})
            release_elements(arg)
            return arg, arg
        end
        function cleanup_arg(jarr::JNIArray{$primitive})
            get_elements!(jarr)
        end
    end
    eval(m)
end
