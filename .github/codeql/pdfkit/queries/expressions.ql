import swift

string startLine(Expr expression) {
  result = expression.getLocation().getStartLine().toString()
  or
  not exists(expression.getLocation().getStartLine()) and result = "MISSING_START_LINE"
}

string primaryClass(Expr expression) {
  result = expression.getAPrimaryQlClass()
  or
  not exists(expression.getAPrimaryQlClass()) and result = "MISSING_PRIMARY_CLASS"
}

string expressionText(Expr expression) {
  result = expression.toString()
  or
  not exists(expression.toString()) and result = "MISSING_EXPRESSION_TEXT"
}

string expressionType(Expr expression) {
  result = expression.getType().getFullName()
  or
  not exists(expression.getType().getFullName()) and result = "MISSING_EXPRESSION_TYPE"
}

string referencedDeclaration(Expr expression) {
  result = expression.(DeclRefExpr).getDecl().toString()
  or
  expression instanceof DeclRefExpr and
  not exists(expression.(DeclRefExpr).getDecl().toString()) and
  result = "UNRESOLVED_DECLARATION_REFERENCE"
  or
  not expression instanceof DeclRefExpr and result = "NOT_DECL_REF_EXPR"
}

string referencedModule(Expr expression) {
  result = expression.(DeclRefExpr).getDecl().getModule().getFullName()
  or
  expression instanceof DeclRefExpr and
  not exists(expression.(DeclRefExpr).getDecl().getModule().getFullName()) and
  result = "MISSING_DECLARATION_MODULE"
  or
  not expression instanceof DeclRefExpr and result = "NOT_DECL_REF_EXPR"
}

from Expr expression
where expression.getFile().getBaseName() = ["FileUtilities.swift", "PDFReader.swift"]
select expression, expression.getFile().getBaseName(), startLine(expression),
  primaryClass(expression), expressionText(expression), expressionType(expression),
  referencedDeclaration(expression), referencedModule(expression)
