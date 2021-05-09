using Test

macro test_false(expr)
    esc(:(@test !($expr)))
end

macro test_nothing(expr)
    esc(:(@test ($expr) === nothing))
end

macro test_passed()
    @test true
end
