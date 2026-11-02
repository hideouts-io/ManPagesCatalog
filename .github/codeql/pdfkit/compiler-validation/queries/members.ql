import swift

string memberText(MemberRefExpr expression) {
  result = expression.getMember().toString()
  or
  not exists(expression.getMember().toString()) and result = "UNRESOLVED_MEMBER"
}

string memberModule(MemberRefExpr expression) {
  result = expression.getMember().getModule().getFullName()
  or
  not exists(expression.getMember().getModule().getFullName()) and
  result = "MISSING_MEMBER_MODULE"
}

string receiverType(MemberRefExpr expression) {
  result = expression.getBase().getType().getFullName()
  or
  not exists(expression.getBase().getType().getFullName()) and
  result = "MISSING_RECEIVER_TYPE"
}

string propertyType(MemberRefExpr expression) {
  result = expression.getMember().(ValueDecl).getInterfaceType().getFullName()
  or
  not exists(expression.getMember().(ValueDecl).getInterfaceType().getFullName()) and
  result = "MISSING_PROPERTY_TYPE"
}

from MemberRefExpr expression
where
  expression.getFile().getBaseName() = "FileUtilities.swift" and
  expression.toString() = [".pageCount", ".string"]
select expression, expression.getFile().getBaseName(), memberText(expression),
  memberModule(expression), receiverType(expression), propertyType(expression)
