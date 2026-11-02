import swift

string targetText(ApplyExpr call) {
  result = call.getStaticTarget().toString()
  or
  not exists(call.getStaticTarget().toString()) and result = "UNRESOLVED_STATIC_TARGET"
}

string targetModule(ApplyExpr call) {
  result = call.getStaticTarget().(Decl).getModule().getFullName()
  or
  not exists(call.getStaticTarget().(Decl).getModule().getFullName()) and
  result = "NO_DECLARATION_MODULE"
}

string resultType(ApplyExpr call) {
  result = call.getType().getFullName()
  or
  not exists(call.getType().getFullName()) and result = "MISSING_RESULT_TYPE"
}

string qualifierType(ApplyExpr call) {
  result = call.getQualifier().getType().getFullName()
  or
  not exists(call.getQualifier().getType().getFullName()) and result = "NO_QUALIFIER_TYPE"
}

from ApplyExpr call
where
  call.getFile().getBaseName() =
    [
      "PDFReader.swift", "PDFDetailView.swift", "ManualCatalog.swift", "FileUtilities.swift",
      "BehaviorHarness.swift", "Probe.swift"
    ]
select call, call.getFile().getBaseName(), targetText(call), targetModule(call), resultType(call),
  qualifierType(call)
