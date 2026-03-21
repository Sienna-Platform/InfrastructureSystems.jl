@scoped_enum(ModelBuildStatus, IN_PROGRESS = -1, BUILT = 0, FAILED = 1, EMPTY = 2,)

Base.convert(::Type{ModelBuildStatus}, val::String) = get_enum_value(ModelBuildStatus, val)
