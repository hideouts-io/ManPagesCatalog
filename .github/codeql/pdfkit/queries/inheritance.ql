import swift

string declarationKind(TypeDecl declaration) {
  declaration instanceof ClassDecl and result = "class"
  or
  declaration instanceof ProtocolDecl and result = "protocol"
  or
  not declaration instanceof ClassDecl and
  not declaration instanceof ProtocolDecl and
  result = "other"
}

string moduleName(Decl declaration) {
  result = declaration.getModule().getFullName()
  or
  not exists(declaration.getModule().getFullName()) and result = "MISSING_MODULE"
}

string declarationName(TypeDecl declaration) {
  result = declaration.getFullName()
  or
  not exists(declaration.getFullName()) and result = "MISSING_FULL_NAME"
}

from NominalTypeDecl declaration, TypeDecl base, string relation
where
  (
    declaration.getName() = ["PDFView", "PDFDocument", "PDFPage", "PDFSelection"]
    or
    declaration.getName().matches("%AccessibilityElement%")
  ) and
  (
    base = declaration and relation = "self"
    or
    base = declaration.getABaseTypeDecl() and relation = "direct"
    or
    base = declaration.getABaseTypeDecl+() and relation = "ancestor"
  )
select declaration, moduleName(declaration), declarationName(declaration),
  declarationKind(declaration), relation, moduleName(base), declarationName(base), declarationKind(base)
