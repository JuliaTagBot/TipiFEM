module Utils

import Base.Iterators.flatten

using MacroTools
using MacroTools: postwalk, prewalk

export flatten, type_scatter, type_gather

struct MethodNotImplemented end

@generated function flatten(a::T) where T <: Union{Tuple, AbstractArray}
  if T <: Tuple
    expr = Expr(:tuple)
    for (i, TT) in enumerate(T.parameters)
      if TT <: Tuple || TT <: AbstractArray
        push!(expr.args, Expr(:..., :(flatten(a[$(i)]))))
      else
        push!(expr.args, :(a[$(i)]))
      end
    end
    expr
  elseif T <: AbstractArray
    error("not implemented")
  else
    :(a)
  end
end

"""
Given a tuple of types returns a tuple of types with all Union
types expanded as tuples
"""
type_scatter(t::Tuple) = map(type_scatter, t)
type_scatter(t::Type) = t
type_scatter(u::Union) = (Base.uniontypes(u)...)

type_gather(t::Tuple) = map(e -> isa(e, Tuple) ? Union{e...} : e, t)

"""
Throw an error if the specified function is called and julia is set to be
in prototyping mode.

Todo: implement
"""
macro prototyping_only(fn_def)
  esc(fn_def)
end

"""
Given an expression return a canonical form of that expression

e.g. transform `a(x::T) where T <: Real = 1` into a{T}(x::T) = 1
"""
function canonicalize(expr::Expr)
  expr = macroexpand(expr)
  expr = longdef(expr)
  postwalk(expr) do ex
    if isa(ex, Expr) && ex.head == :where
      @capture(ex, f_(args__) where Ts__)
      Expr(:call, Expr(:curly, f, Ts...), args...)
    else
      ex
    end
  end
end

type InvalidVecFnExprException <: Exception
  msg::String
  expr::Expr
end

function extract_return_types(body; error=error)
  return_types = []
  # find all return statements
  postwalk(body) do sub_expr
    if isa(sub_expr, Expr) && sub_expr.head != :block &&
        @capture(sub_expr, return (return_type_(args__) | return_expr_::return_type_))
      push!(return_types, return_type)
    end
    sub_expr
  end
  # the last statement is also a return statement
  let last_expr = body.args[end]
    assert(isa(last_expr, Expr))
    if isa(last_expr, Expr) && last_expr.head != :return
      @capture(last_expr, (return_type_(args__) | return_expr_::return_type_))
      push!(return_types, return_type)
    end
  end
  return_types
end

import Base.zeros
@generated function zero(::Type{NTuple{N, T}}) where {N, T <: Number}
  expr = Expr(:tuple)
  for i = 1:N
    push!(expr.args, 0)
  end
  expr
end

"""
Given a vectorized function definition generate an additional non vectorized
function definition. The vector width may be annotated by wrapping it into a
`@VectorWidth` macro call which is removed during expansion.

```@eval
expr=:(@generate_sisd a{num_points}(x::SMatrix{@VectorWidth(num_points), 2}) = x)
macroexpand(expr)
```

TODO: Currently this only works if the vectorized argument has been an SVector
resulting in an SMatrix. If the vectoized argument however has been a Scalar
an SVector would result, which is currently not supported by this macro.
"""
macro generate_sisd(expr)
  # helper function
  error = msg -> throw(InvalidVecFnExprException(msg, expr))
  #
  # search for the VecWidth argument
  #-(1-x̂[:, 2]),  -(1-x̂[:, 1])
  vector_width = nothing
  expr = prewalk(expr) do sub_expr
    if @capture(sub_expr, @VectorWidth(tmp_))
      vector_width = tmp
      sub_expr = vector_width
    end
    sub_expr
  end
  vector_width!=nothing || error("Vector width not found in expr: $(expr)")
  #
  # decompose expression
  #
  expr = canonicalize(expr) # rewrite expression in a canonical form
  expr = macroexpand(expr) # expand macros
  # ensure that the expression is a function definition
  expr.head ∈ (:function, :stagedfunction) || error("Expected function definition")
  sig = expr.args[1] # extract function signature
  body = expr.args[2] # extract function body
  body.head == :block || error("Unexpted syntax") # we take this for granted later on
  # decompose function signature
  @capture(sig, (f_{Ts__}(args__)) | f_{Ts__}(args__)::return_type_) || error("Expected function definition")
  # find all return types
  #  if the return type has been annotated in the signature use that type
  # otherwise search in the function body
  return_types = return_type == nothing ? extract_return_types(body, error=error) : [return_type]
  length(return_types)!=0 || error("Could not find return statement in $(expr)")
  length(return_types)==1 || error("Only a single return statement supported by now")
  #
  # parse expression
  #
  # remove vector width argument from parametric type arguments
  sisd_Ts=filter(Ts) do Targ
    @capture(Targ, T_ | (T_ <: B_)) || error("Unexpected syntax")
    T != vector_width
  end
  # remove :curly
  # rewrite arguments
  vector_args = Array{Bool, 1}(length(args))
  sisd_args = map(1:length(args), args) do i, arg
    # rewrite vector arguments into scalar arguments
    # todo: allow function that do not specify T
    is_vector_arg = vector_args[i] = @capture(arg, x_::SMatrix{n_, m_, T_})
    if is_vector_arg && n == vector_width
      arg = :($(x)::SVector{$(m), $(T)})
    end
    # rewrite unlabeled arguments
    is_unlabeled = @capture(arg, ::T_)
    if is_unlabeled
      arg = Expr(:(::), gensym(), T)
    end
    arg
  end
  # extract argument labels
  forward_args = map(1:length(sisd_args), sisd_args) do i, arg
    @capture(arg, (x_::T_) | x_Symbol) || error("Unexpected syntax")
    if vector_args[i]
      @capture(arg, y_::SVector{m_, T_Symbol}) ||
        @capture(arg, y_::SVector{m_, T_Symbol <: TT_})
      @assert T != nothing "Unexpected syntax"
      x=:(convert(SMatrix{1, $(m), $(T)}, $(x)))
    end
    x
  end
  # generate call expression to the SIMD version
  forward_call_expr = Expr(:call, f, forward_args...)
  # generate expression that converts the return type from the SIMD into the SISD version
  call_expr = nothing
  for return_type in return_types
    @capture(return_type, T_{TT__} | T_) || error("Can not process return type $(return_type)")

    if T ∈ (:SArray, :SMatrix, :SVector)
      dims = if T == :SArray
        [TT[1]]
      elseif T == :SMatrix
        TT[1:2]
      else T == :SVector
        [TT[1]]
      end
      # search for the dimension(s) that contains the VectorWidth
      vector_dims = find(dim -> dim==vector_width, dims)
      call_expr = Expr(:ref, forward_call_expr)
      for i in 1:length(dims)
        push!(call_expr.args, i ∈ vector_dims ? 1 : :(:))
      end
    else
      error("Can not process return type $(return_type)")
    end
  end
  sisd_expr = Expr(:function,
                   Expr(:call, Expr(:curly, f, sisd_Ts...), sisd_args...),
                   call_expr)
  esc(Expr(:block, :(Base.@__doc__ $(expr)), sisd_expr))
end

end