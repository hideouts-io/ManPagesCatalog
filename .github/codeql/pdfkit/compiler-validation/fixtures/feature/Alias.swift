import FeatureProbe

public func validationImportedAlias(_ value: Int32) -> Int32 {
    ValidationFunctionAlias(value)
}

public func validationLiterals() -> [Int32] {
    [ValidationLiteral, ValidationLiteralAlias, ValidationLiteralChain]
}
