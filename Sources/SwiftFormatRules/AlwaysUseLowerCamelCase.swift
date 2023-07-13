//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SwiftFormatCore
import SwiftSyntax

/// All values should be written in lower camel-case (`lowerCamelCase`).
/// Underscores (except at the beginning of an identifier) are disallowed.
///
/// Lint: If an identifier contains underscores or begins with a capital letter, a lint error is
///       raised.
public final class AlwaysUseLowerCamelCase: SyntaxLintRule {
  /// Stores function decls that are test cases.
  private var testCaseFuncs = Set<FunctionDeclSyntax>()

  public override func visit(_ node: SourceFileSyntax) -> SyntaxVisitorContinueKind {
    // Tracks whether "XCTest" is imported in the source file before processing individual nodes.
    setImportsXCTest(context: context, sourceFile: node)
    return .visitChildren
  }

  public override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
    guard context.importsXCTest == .importsXCTest else { return .visitChildren }

    collectTestMethods(from: node.memberBlock.members, into: &testCaseFuncs)
    return .visitChildren
  }

  public override func visitPost(_ node: ClassDeclSyntax) {
    testCaseFuncs.removeAll()
  }

  public override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
    // Don't diagnose any issues when the variable is overriding, because this declaration can't
    // rename the variable. If the user analyzes the code where the variable is really declared,
    // then the diagnostic can be raised for just that location.
    if let modifiers = node.modifiers, modifiers.has(modifier: "override") {
      return .visitChildren
    }

    for binding in node.bindings {
      guard let pat = binding.pattern.as(IdentifierPatternSyntax.self) else {
        continue
      }
      diagnoseLowerCamelCaseViolations(
        pat.identifier, allowUnderscores: false, description: identifierDescription(for: node))
    }
    return .visitChildren
  }

  public override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
    guard let pattern = node.pattern.as(IdentifierPatternSyntax.self) else {
      return .visitChildren
    }
    diagnoseLowerCamelCaseViolations(
      pattern.identifier, allowUnderscores: false, description: identifierDescription(for: node))
    return .visitChildren
  }

  public override func visit(_ node: ClosureSignatureSyntax) -> SyntaxVisitorContinueKind {
    if let parameterClause = node.parameterClause {
      if let closureParamList = parameterClause.as(ClosureParamListSyntax.self) {
        for param in closureParamList {
          diagnoseLowerCamelCaseViolations(
            param.name, allowUnderscores: false, description: identifierDescription(for: node))
        }
      } else if let closureParameterClause = parameterClause.as(ClosureParameterClauseSyntax.self) {
        for param in closureParameterClause.parameterList {
          diagnoseLowerCamelCaseViolations(
            param.firstName, allowUnderscores: false, description: identifierDescription(for: node))
          if let secondName = param.secondName {
            diagnoseLowerCamelCaseViolations(
              secondName, allowUnderscores: false, description: identifierDescription(for: node))
          }
        }
      } else if let enumCaseParameterClause = parameterClause.as(EnumCaseParameterClauseSyntax.self) {
        for param in enumCaseParameterClause.parameterList {
          if let firstName = param.firstName {
            diagnoseLowerCamelCaseViolations(
              firstName, allowUnderscores: false, description: identifierDescription(for: node))
          }
          if let secondName = param.secondName {
            diagnoseLowerCamelCaseViolations(
              secondName, allowUnderscores: false, description: identifierDescription(for: node))
          }
        }
      } else if let parameterClause = parameterClause.as(ParameterClauseSyntax.self) {
        for param in parameterClause.parameterList {
          diagnoseLowerCamelCaseViolations(
            param.firstName, allowUnderscores: false, description: identifierDescription(for: node))
          if let secondName = param.secondName {
            diagnoseLowerCamelCaseViolations(
              secondName, allowUnderscores: false, description: identifierDescription(for: node))
          }
        }
      }
    }
    return .visitChildren
  }

  public override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    // Don't diagnose any issues when the function is overriding, because this declaration can't
    // rename the function. If the user analyzes the code where the function is really declared,
    // then the diagnostic can be raised for just that location.
    if let modifiers = node.modifiers, modifiers.has(modifier: "override") {
      return .visitChildren
    }

    // We allow underscores in test names, because there's an existing convention of using
    // underscores to separate phrases in very detailed test names.
    let allowUnderscores = testCaseFuncs.contains(node)
    diagnoseLowerCamelCaseViolations(
      node.identifier, allowUnderscores: allowUnderscores,
      description: identifierDescription(for: node))
    for param in node.signature.parameterClause.parameterList {
      // These identifiers aren't described using `identifierDescription(for:)` because no single
      // node can disambiguate the argument label from the parameter name.
      diagnoseLowerCamelCaseViolations(
        param.firstName, allowUnderscores: false, description: "argument label")
      if let paramName = param.secondName {
        diagnoseLowerCamelCaseViolations(
          paramName, allowUnderscores: false, description: "function parameter")
      }
    }
    return .visitChildren
  }

  public override func visit(_ node: EnumCaseElementSyntax) -> SyntaxVisitorContinueKind {
    diagnoseLowerCamelCaseViolations(
      node.identifier, allowUnderscores: false, description: identifierDescription(for: node))
    return .skipChildren
  }

  /// Collects methods that look like XCTest test case methods from the given member list, inserting
  /// them into the given set.
  private func collectTestMethods(
    from members: MemberDeclListSyntax,
    into set: inout Set<FunctionDeclSyntax>
  ) {
    for member in members {
      if let ifConfigDecl = member.decl.as(IfConfigDeclSyntax.self) {
        // Recurse into any conditional member lists and collect their test methods as well.
        for clause in ifConfigDecl.clauses {
          if let clauseMembers = clause.elements?.as(MemberDeclListSyntax.self) {
            collectTestMethods(from: clauseMembers, into: &set)
          }
        }
      } else if let functionDecl = member.decl.as(FunctionDeclSyntax.self) {
        // Identify test methods using the same heuristics as XCTest: name starts with "test", has
        // no arguments, and returns a void type.
        if functionDecl.identifier.text.starts(with: "test")
            && functionDecl.signature.parameterClause.parameterList.isEmpty
            && (functionDecl.signature.returnClause.map(\.isVoid) ?? true)
        {
          set.insert(functionDecl)
        }
      }
    }
  }

  private func diagnoseLowerCamelCaseViolations(
    _ identifier: TokenSyntax, allowUnderscores: Bool, description: String
  ) {
    guard case .identifier(let text) = identifier.tokenKind else { return }
    if text.isEmpty { return }
    if (text.dropFirst().contains("_") && !allowUnderscores) || ("A"..."Z").contains(text.first!) {
      diagnose(.nameMustBeLowerCamelCase(text, description: description), on: identifier)
    }
  }
}

/// Returns a human readable description of the node type that can be used to describe the
/// identifier of the node in diagnostics from this rule.
///
/// - Parameter node: A node whose identifier may be used in diagnostics.
/// - Returns: A human readable description of the node and its identifier.
fileprivate func identifierDescription<NodeType: SyntaxProtocol>(for node: NodeType) -> String {
  switch Syntax(node).as(SyntaxEnum.self) {
  case .closureSignature: return "closure parameter"
  case .enumCaseElement: return "enum case"
  case .functionDecl: return "function"
  case .optionalBindingCondition(let binding):
    return binding.bindingSpecifier.tokenKind == .keyword(.var) ? "variable" : "constant"
  case .variableDecl(let variableDecl):
    return variableDecl.bindingSpecifier.tokenKind == .keyword(.var) ? "variable" : "constant"
  default:
    return "identifier"
  }
}

extension ReturnClauseSyntax {
  /// Whether this return clause specifies an explicit `Void` return type.
  fileprivate var isVoid: Bool {
    if let returnTypeIdentifier = returnType.as(SimpleTypeIdentifierSyntax.self) {
      return returnTypeIdentifier.name.text == "Void"
    }
    if let returnTypeTuple = returnType.as(TupleTypeSyntax.self) {
      return returnTypeTuple.elements.isEmpty
    }
    return false
  }
}

extension Finding.Message {
  public static func nameMustBeLowerCamelCase(
    _ name: String, description: String
  ) -> Finding.Message {
    "rename \(description) '\(name)' using lower-camel-case"
  }
}
