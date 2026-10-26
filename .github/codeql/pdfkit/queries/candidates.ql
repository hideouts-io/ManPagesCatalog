import swift

string declarationKind(TypeDecl declaration) {
  declaration instanceof ClassDecl and result = "class"
  or
  declaration instanceof ProtocolDecl and result = "protocol"
  or
  declaration instanceof TypeAliasDecl and result = "typealias"
  or
  not declaration instanceof ClassDecl and
  not declaration instanceof ProtocolDecl and
  not declaration instanceof TypeAliasDecl and
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

string declaredType(TypeDecl declaration) {
  result = declaration.getDeclaredInterfaceType().getFullName()
  or
  not exists(declaration.getDeclaredInterfaceType().getFullName()) and
  result = "MISSING_DECLARED_TYPE"
}

from TypeDecl declaration
where
  declaration.getName().matches("%AccessibilityElement%")
  or
  declaration.getName() = "PDFKitPlatformAccessibilityElement"
select declaration, declarationKind(declaration), moduleName(declaration),
  declarationName(declaration), declaredType(declaration), count(declaration.getABaseTypeDecl())
