import FeatureProbe

public func validationLiterals() -> [Int32] {
    [ValidationLiteral, ValidationLiteralAlias, ValidationLiteralChain]
}

public func validationDirectCall(_ value: Int32) -> Int32 {
    validation_function(value)
}
