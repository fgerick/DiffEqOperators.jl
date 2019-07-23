function LinearAlgebra.mul!(x_temp::AbstractArray{T}, A::DerivativeOperator{T,N}, M::AbstractArray{T}) where {T,N}

    # Check that x_temp has correct dimensions
    v = zeros(ndims(x_temp))
    v[N] = 2
    @assert [size(x_temp)...]+v == [size(M)...]

    # Check that axis of differentiation is in the dimensions of M and x_temp
    ndimsM = ndims(M)
    @assert N <= ndimsM

    dimsM = [axes(M)...]
    alldims = [1:ndims(M);]
    otherdims = setdiff(alldims, N)

    idx = Any[first(ind) for ind in axes(M)]
    itershape = tuple(dimsM[otherdims]...)
    nidx = length(otherdims)
    indices = Iterators.drop(CartesianIndices(itershape), 0)

    setindex!(idx, :, N)
    for I in indices
        Base.replace_tuples!(nidx, idx, idx, otherdims, I)
        mul!(view(x_temp, idx...), A, view(M, idx...))
    end
end

for MT in [2,3]
    @eval begin
        function LinearAlgebra.mul!(x_temp::AbstractArray{T,$MT}, A::DerivativeOperator{T,N,false,T2,S1,S2,T3}, M::AbstractArray{T,$MT}) where
                                                                            {T,N,T2,SL,S1<:SArray{Tuple{SL},T,1,SL},S2,T3<:Union{Nothing,Number}}
            # Check that x_temp has correct dimensions
            v = zeros(ndims(x_temp))
            v[N] = 2
            @assert [size(x_temp)...]+v == [size(M)...]

            # Check that axis of differentiation is in the dimensions of M and x_temp
            ndimsM = ndims(M)
            @assert N <= ndimsM

            # Determine padding for NNlib.conv!
            bpc = A.boundary_point_count
            pad = zeros(Int64,ndimsM)
            pad[N] = bpc

            # Reshape x_temp for NNlib.conv!
            _x_temp = reshape(x_temp, (size(x_temp)...,1,1))

            # Reshape M for NNlib.conv!
            _M = reshape(M, (size(M)...,1,1))

            # Setup W, the kernel for NNlib.conv!
            s = A.stencil_coefs
            sl = A.stencil_length
            Wdims = ones(Int64, ndims(_x_temp))
            Wdims[N] = sl
            W = zeros(Wdims...)
            Widx = Any[Wdims...]
            setindex!(Widx,:,N)
            coeff = A.coefficients === nothing ? true : A.coefficients
            W[Widx...] = coeff*s

            cv = DenseConvDims(_M, W, padding=pad,flipkernel=true)
            conv!(_x_temp, _M, W, cv)

            # Now deal with boundaries
            if bpc > 0
                dimsM = [axes(M)...]
                alldims = [1:ndims(M);]
                otherdims = setdiff(alldims, N)

                idx = Any[first(ind) for ind in axes(M)]
                itershape = tuple(dimsM[otherdims]...)
                nidx = length(otherdims)
                indices = Iterators.drop(CartesianIndices(itershape), 0)

                setindex!(idx, :, N)
                for I in indices
                    Base.replace_tuples!(nidx, idx, idx, otherdims, I)
                    convolve_BC_left!(view(x_temp, idx...), view(M, idx...), A)
                    convolve_BC_right!(view(x_temp, idx...), view(M, idx...), A)
                end
            end
        end
    end
end

function *(A::DerivativeOperator{T,N},M::AbstractArray{T}) where {T<:Real,N}
    size_x_temp = [size(M)...]
    size_x_temp[N] -= 2
    x_temp = zeros(promote_type(eltype(A),eltype(M)), size_x_temp...)
    LinearAlgebra.mul!(x_temp, A, M)
    return x_temp
end

function *(c::Number, A::DerivativeOperator{T,N,Wind}) where {T,N,Wind}
    coefficients = A.coefficients === nothing ? one(T)*c : c*A.coefficients
    DerivativeOperator{T,N,Wind,typeof(A.dx),typeof(A.stencil_coefs),
                       typeof(A.low_boundary_coefs),typeof(coefficients),
                       typeof(A.coeff_func)}(
        A.derivative_order, A.approximation_order,
        A.dx, A.len, A.stencil_length,
        A.stencil_coefs,
        A.boundary_stencil_length,
        A.boundary_point_count,
        A.low_boundary_coefs,
        A.high_boundary_coefs,coefficients,A.coeff_func)
end

# Inplace left division
function LinearAlgebra.ldiv!(M_temp::AbstractArray{T,MT}, A::DerivativeOperator{T,N}, M::AbstractArray{T,MT}) where {T<:Real, N, MT}

    # The case where M is a vector or matrix and A is differentiating along the first dimension
    if N == 1 && MT <= 2
        ldiv!(M_temp, factorize(Array(A)), M)

    # The case where M is differentiating along an arbitrary dimension
    else
        Mshape = size(M)

        # Case where the first dimension is not being differentiated
        if N != 1

            # Compute the high dimensional concretization B of A

            B = Matrix(I, Mshape[1],Mshape[1])
            for i in length(Mshape)-1:-1:1
                if N != length(Mshape) - i + 1
                    B = Kron(Matrix(I,Mshape[i],Mshape[i]),B)
                else
                    B = Kron(Array(A),B)
                end
            end

        # Case where the first dimension is being differentiated
        else
            B = Array(A)
            for i in len(Mshape)-1:1
                B = Kron(Matrix(I,Mshape[i],Mshape[i]),B)
            end
        end

        # compute ldiv!
        ldiv!(vec(M_temp), factorize(Array(B)), vec(M))
    end
end

# Non-inplace left division.
function \(A::DerivativeOperator{T,N}, M::AbstractArray{T,MT}) where {T<:Real, N,MT}
    # The case where M is a vector or matrix and A is differentiating along the first dimension
    if N == 1 && MT <= 2
        sparse(A) \ M

    # The case where M is differentiating along an arbitrary dimension
    else
        Mshape = size(M)

        # Case where the first dimension is not being differentiated
        if N != 1

            # Compute the high dimensional concretization B of A

            B = sparse(I, Mshape[1],Mshape[1])
            for i in length(Mshape)-1:-1:1
                if N != length(Mshape) - i + 1
                    B = Kron(sparse(I,Mshape[i],Mshape[i]),B)
                else
                    B = Kron(sparse(A),B)
                end
            end

        # Case where the first dimension is being differentiated
        else
            B = sparse(A)
            for i in len(Mshape)-1:1
                B = Kron(sparse(I,Mshape[i],Mshape[i]),B)
            end
        end

        # compute ldiv!
        new_shape = [size(M)...]
        new_shape[N] += 2
        return reshape(sparse(B)\vec(M), new_shape...)
    end
end
