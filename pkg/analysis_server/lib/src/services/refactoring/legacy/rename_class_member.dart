// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/protocol_server.dart'
    hide Element, ElementKind;
import 'package:analysis_server/src/services/correction/status.dart';
import 'package:analysis_server/src/services/correction/util.dart';
import 'package:analysis_server/src/services/refactoring/legacy/naming_conventions.dart';
import 'package:analysis_server/src/services/refactoring/legacy/refactoring.dart';
import 'package:analysis_server/src/services/refactoring/legacy/refactoring_internal.dart';
import 'package:analysis_server/src/services/refactoring/legacy/rename.dart';
import 'package:analysis_server/src/services/refactoring/legacy/visible_ranges_computer.dart';
import 'package:analysis_server/src/services/search/hierarchy.dart';
import 'package:analysis_server/src/services/search/search_engine.dart';
import 'package:analysis_server/src/utilities/strings.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/src/dart/analysis/session_helper.dart';
import 'package:analyzer/src/generated/java_core.dart';
import 'package:analyzer/src/generated/source.dart';

/// Checks if creating a method with the given [name] in [interfaceElement] will
/// cause any conflicts.
Future<RefactoringStatus> validateCreateMethod(
    SearchEngine searchEngine,
    AnalysisSessionHelper sessionHelper,
    InterfaceElement interfaceElement,
    String name) {
  return _CreateClassMemberValidator(
          searchEngine, sessionHelper, interfaceElement, name)
      .validate();
}

/// A [Refactoring] for renaming class member [Element]s.
class RenameClassMemberRefactoringImpl extends RenameRefactoringImpl {
  final AnalysisSessionHelper sessionHelper;
  final ClassElement classElement;

  late _RenameClassMemberValidator _validator;

  RenameClassMemberRefactoringImpl(RefactoringWorkspace workspace,
      AnalysisSession session, this.classElement, Element element)
      : sessionHelper = AnalysisSessionHelper(session),
        super(workspace, element);

  @override
  String get refactoringName {
    if (element is TypeParameterElement) {
      return 'Rename Type Parameter';
    }
    if (element is FieldElement) {
      return 'Rename Field';
    }
    return 'Rename Method';
  }

  @override
  Future<RefactoringStatus> checkFinalConditions() {
    _validator = _RenameClassMemberValidator(
        searchEngine, sessionHelper, classElement, element, newName);
    return _validator.validate();
  }

  @override
  Future<RefactoringStatus> checkInitialConditions() async {
    var result = await super.checkInitialConditions();
    if (element is MethodElement && (element as MethodElement).isOperator) {
      result.addFatalError('Cannot rename operator.');
    }
    return Future<RefactoringStatus>.value(result);
  }

  @override
  RefactoringStatus checkNewName() {
    var result = super.checkNewName();
    if (element is FieldElement) {
      result.addStatus(validateFieldName(newName));
    }
    if (element is MethodElement) {
      result.addStatus(validateMethodName(newName));
    }
    return result;
  }

  @override
  Future<void> fillChange() async {
    var processor = RenameProcessor(workspace, change, newName);
    // update declarations
    for (var renameElement in _validator.elements) {
      if (renameElement.isSynthetic && renameElement is FieldElement) {
        processor.addDeclarationEdit(renameElement.getter);
        processor.addDeclarationEdit(renameElement.setter);
      } else {
        processor.addDeclarationEdit(renameElement);
      }
    }
    // update references
    processor.addReferenceEdits(_validator.references);
    // potential matches
    var nameMatches = await searchEngine.searchMemberReferences(oldName);
    var nameRefs = getSourceReferences(nameMatches);
    for (var reference in nameRefs) {
      // ignore references from SDK and pub cache
      if (!workspace.containsElement(reference.element)) {
        continue;
      }
      // check the element being renamed is accessible
      if (!element.isAccessibleIn2(reference.libraryElement)) {
        continue;
      }
      // add edit
      reference.addEdit(change, newName, id: _newPotentialId());
    }
  }

  String _newPotentialId() {
    var id = potentialEditIds.length.toString();
    potentialEditIds.add(id);
    return id;
  }
}

/// The base class for the create and rename validators.
class _BaseClassMemberValidator {
  final SearchEngine searchEngine;
  final AnalysisSessionHelper sessionHelper;
  final InterfaceElement interfaceElement;
  final ElementKind elementKind;
  final String name;

  final RefactoringStatus result = RefactoringStatus();

  _BaseClassMemberValidator(
    this.searchEngine,
    this.sessionHelper,
    this.interfaceElement,
    this.elementKind,
    this.name,
  );

  LibraryElement get library => interfaceElement.library;

  void _checkClassAlreadyDeclares() {
    // check if there is a member with "newName" in the same ClassElement
    for (var newNameMember in getChildren(interfaceElement, name)) {
      result.addError(
        format(
          "{0} '{1}' already declares {2} with name '{3}'.",
          capitalize(interfaceElement.kind.displayName),
          interfaceElement.displayName,
          getElementKindName(newNameMember),
          name,
        ),
        newLocation_fromElement(newNameMember),
      );
    }
  }

  Future<void> _checkHierarchy({
    required bool isRename,
    required Set<InterfaceElement> subClasses,
  }) async {
    var superClasses =
        interfaceElement.allSupertypes.map((e) => e.element2).toSet();
    // check shadowing in the hierarchy
    var declarations = await searchEngine.searchMemberDeclarations(name);
    for (var declaration in declarations) {
      var nameElement = getSyntheticAccessorVariable(declaration.element);
      var nameClass = nameElement.enclosingElement3;
      // the renamed Element shadows a member of a superclass
      if (superClasses.contains(nameClass)) {
        result.addError(
            format(
                isRename
                    ? "Renamed {0} will shadow {1} '{2}'."
                    : "Created {0} will shadow {1} '{2}'.",
                elementKind.displayName,
                getElementKindName(nameElement),
                getElementQualifiedName(nameElement)),
            newLocation_fromElement(nameElement));
      }
      // the renamed Element is shadowed by a member of a subclass
      if (isRename && subClasses.contains(nameClass)) {
        result.addError(
            format(
                "Renamed {0} will be shadowed by {1} '{2}'.",
                elementKind.displayName,
                getElementKindName(nameElement),
                getElementQualifiedName(nameElement)),
            newLocation_fromElement(nameElement));
      }
    }
  }
}

/// Helper to check if the created element will cause any conflicts.
class _CreateClassMemberValidator extends _BaseClassMemberValidator {
  _CreateClassMemberValidator(
      SearchEngine searchEngine,
      AnalysisSessionHelper sessionHelper,
      InterfaceElement interfaceElement,
      String name)
      : super(
          searchEngine,
          sessionHelper,
          interfaceElement,
          ElementKind.METHOD,
          name,
        );

  Future<RefactoringStatus> validate() async {
    _checkClassAlreadyDeclares();
    // do chained computations
    var subClasses = await searchEngine.searchAllSubtypes(interfaceElement);
    // check shadowing of class names
    if (interfaceElement.name == name) {
      result.addError(
        'Created ${elementKind.displayName} has the same name as the '
        "declaring ${interfaceElement.kind.displayName} '$name'.",
        newLocation_fromElement(interfaceElement),
      );
    }
    // check shadowing in the hierarchy
    await _checkHierarchy(
      isRename: false,
      subClasses: subClasses,
    );
    // done
    return result;
  }
}

class _LocalElementsCollector extends GeneralizingAstVisitor<void> {
  final String name;
  final List<LocalElement> elements = [];

  _LocalElementsCollector(this.name);

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    var element = node.staticElement;
    if (element is LocalElement && element.name == name) {
      elements.add(element);
    }
  }
}

class _MatchShadowedByLocal {
  final SearchMatch match;
  final LocalElement localElement;

  _MatchShadowedByLocal(this.match, this.localElement);
}

/// Helper to check if the renamed [element] will cause any conflicts.
class _RenameClassMemberValidator extends _BaseClassMemberValidator {
  final Element element;

  Set<Element> elements = <Element>{};
  List<SearchMatch> references = <SearchMatch>[];

  _RenameClassMemberValidator(
    SearchEngine searchEngine,
    AnalysisSessionHelper sessionHelper,
    ClassElement elementClass,
    this.element,
    String name,
  ) : super(searchEngine, sessionHelper, elementClass, element.kind, name);

  Future<RefactoringStatus> validate() async {
    _checkClassAlreadyDeclares();
    // do chained computations
    await _prepareReferences();
    var subClasses = await searchEngine.searchAllSubtypes(interfaceElement);
    // check shadowing of class names
    for (var element in elements) {
      var enclosingElement = element.enclosingElement3;
      if (enclosingElement is ClassElement && enclosingElement.name == name) {
        result.addError(
          'Renamed ${elementKind.displayName} has the same name as the '
          "declaring ${enclosingElement.kind.displayName} '$name'.",
          newLocation_fromElement(element),
        );
      }
    }
    // usage of the renamed Element is shadowed by a local element
    {
      var conflict = await _getShadowingLocalElement();
      if (conflict != null) {
        var localElement = conflict.localElement;
        result.addError(
            format(
                "Usage of renamed {0} will be shadowed by {1} '{2}'.",
                elementKind.displayName,
                getElementKindName(localElement),
                localElement.displayName),
            newLocation_fromMatch(conflict.match));
      }
    }
    // check shadowing in the hierarchy
    await _checkHierarchy(
      isRename: true,
      subClasses: subClasses,
    );
    // visibility
    _validateWillBeInvisible();
    // done
    return result;
  }

  Future<_MatchShadowedByLocal?> _getShadowingLocalElement() async {
    var localElementMap = <CompilationUnitElement, List<LocalElement>>{};
    var visibleRangeMap = <LocalElement, SourceRange>{};

    Future<List<LocalElement>> getLocalElements(Element element) async {
      var unitElement = element.thisOrAncestorOfType<CompilationUnitElement>();
      if (unitElement == null) {
        return const [];
      }

      var localElements = localElementMap[unitElement];

      if (localElements == null) {
        var result = await sessionHelper.getResolvedUnitByElement(element);
        if (result == null) {
          return const [];
        }

        var unit = result.unit;

        var collector = _LocalElementsCollector(name);
        unit.accept(collector);
        localElements = collector.elements;
        localElementMap[unitElement] = localElements;

        visibleRangeMap.addAll(VisibleRangesComputer.forNode(unit));
      }

      return localElements;
    }

    for (var match in references) {
      // Qualified reference cannot be shadowed by local elements.
      if (match.isQualified) {
        continue;
      }
      // Check local elements that might shadow the reference.
      var localElements = await getLocalElements(match.element);
      for (var localElement in localElements) {
        var elementRange = visibleRangeMap[localElement];
        if (elementRange != null &&
            elementRange.intersects(match.sourceRange)) {
          return _MatchShadowedByLocal(match, localElement);
        }
      }
    }
    return null;
  }

  /// Fills [elements] with [Element]s to rename.
  Future _prepareElements() async {
    final element = this.element;
    if (element is ClassMemberElement) {
      elements = await getHierarchyMembers(searchEngine, element);
    } else {
      elements = {element};
    }
  }

  /// Fills [references] with all references to [elements].
  Future _prepareReferences() async {
    await _prepareElements();
    await Future.forEach(elements, (Element element) async {
      var elementReferences = await searchEngine.searchReferences(element);
      references.addAll(elementReferences);
    });
  }

  /// Validates if any usage of [element] renamed to [name] will be invisible.
  void _validateWillBeInvisible() {
    if (!Identifier.isPrivateName(name)) {
      return;
    }
    for (var reference in references) {
      var refElement = reference.element;
      var refLibrary = refElement.library!;
      if (refLibrary != library) {
        var message = format("Renamed {0} will be invisible in '{1}'.",
            getElementKindName(element), getElementQualifiedName(refLibrary));
        result.addError(message, newLocation_fromMatch(reference));
      }
    }
  }
}
