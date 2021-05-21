# Configuration file for test variables
# Not synched to github as each environment can have different configurations
# See baseconfig.jl to see the expected variables
include("config.jl")

# Setup initializes single VM used by the tests
# Will be destroyed in teardown
# Tests only include the JNI package and the jvm will be running
include("setup.jl")

@testset verbose=true "JavaCall" begin
    # Test init options
    @info "Testing init opts"
    include("initopts.jl")

    # Test jni api
    @info "Testing JNI API"
    include("jni.jl")

    # Test signatures
    @info "Test signatures"
    include("signatures.jl")

    # Test code generation
    @info "Test Code Generation"
    include("codegeneration.jl")

    # Test java lang
    @info "Test Java Lang"
    include("javalang.jl")

    # Test reflection api
    @info "Test Reflection API"
    include("reflection.jl")
end

include("teardown.jl")
