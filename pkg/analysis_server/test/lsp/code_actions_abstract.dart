// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/lsp_protocol/protocol.dart';
import 'package:collection/collection.dart';
import 'package:test/test.dart';

import 'server_abstract.dart';

abstract class AbstractCodeActionsTest extends AbstractLspAnalysisServerTest {
  Future<void> checkCodeActionAvailable(
    Uri uri,
    String command,
    String title, {
    Range? range,
    Position? position,
    bool asCodeActionLiteral = false,
    bool asCommand = false,
  }) async {
    final codeActions =
        await getCodeActions(uri.toString(), range: range, position: position);
    final codeAction = findCommand(codeActions, command)!;

    codeAction.map(
      (command) {
        if (!asCommand) {
          throw 'Got Command but expected CodeAction literal';
        }
        expect(command.title, equals(title));
        expect(
          command.arguments,
          equals([
            {'path': uri.toFilePath()}
          ]),
        );
      },
      (codeAction) {
        if (!asCodeActionLiteral) {
          throw 'Got CodeAction literal but expected Command';
        }
        expect(codeAction.title, equals(title));
        expect(codeAction.command!.title, equals(title));
        expect(
          codeAction.command!.arguments,
          equals([
            {'path': uri.toFilePath()}
          ]),
        );
      },
    );
  }

  Either2<Command, CodeAction>? findCommand(
      List<Either2<Command, CodeAction>> actions, String commandID,
      [String? wantedTitle]) {
    for (var codeAction in actions) {
      final id = codeAction.map(
          (cmd) => cmd.command, (action) => action.command?.command);
      final title =
          codeAction.map((cmd) => cmd.title, (action) => action.title);
      if (id == commandID && (wantedTitle == null || wantedTitle == title)) {
        return codeAction;
      }
    }
    return null;
  }

  CodeAction? findEditAction(List<Either2<Command, CodeAction>> actions,
      CodeActionKind actionKind, String title) {
    return findEditActions(actions, actionKind, title).firstOrNull;
  }

  List<CodeAction> findEditActions(List<Either2<Command, CodeAction>> actions,
      CodeActionKind actionKind, String title) {
    return actions
        .map((action) => action.map((cmd) => null, (action) => action))
        .where((action) => action?.kind == actionKind && action?.title == title)
        .map((action) {
          // Expect matching actions to contain an edit and not a command.
          assert(action!.command == null);
          assert(action!.edit != null);
          return action;
        })
        .whereNotNull()
        .toList();
  }

  /// Verifies that executing the given code actions command on the server
  /// results in an edit being sent in the client that updates the file to match
  /// the expected content.
  Future verifyCodeActionEdits(Either2<Command, CodeAction> codeAction,
      String content, String expectedContent,
      {bool expectDocumentChanges = false,
      ProgressToken? workDoneToken}) async {
    final command = codeAction.map(
      (command) => command,
      (codeAction) => codeAction.command!,
    );

    await verifyCommandEdits(command, content, expectedContent,
        expectDocumentChanges: expectDocumentChanges,
        workDoneToken: workDoneToken);
  }

  /// Verifies that executing the given command on the server results in an edit
  /// being sent in the client that updates the file to match the expected
  /// content.
  Future<void> verifyCommandEdits(
      Command command, String content, String expectedContent,
      {bool expectDocumentChanges = false,
      ProgressToken? workDoneToken}) async {
    ApplyWorkspaceEditParams? editParams;

    final commandResponse = await handleExpectedRequest<Object?,
        ApplyWorkspaceEditParams, ApplyWorkspaceEditResult>(
      Method.workspace_applyEdit,
      ApplyWorkspaceEditParams.fromJson,
      () => executeCommand(command, workDoneToken: workDoneToken),
      handler: (edit) {
        // When the server sends the edit back, just keep a copy and say we
        // applied successfully (it'll be verified below).
        editParams = edit;
        return ApplyWorkspaceEditResult(applied: true);
      },
    );
    // Successful edits return an empty success() response.
    expect(commandResponse, isNull);

    // Ensure the edit came back, and using the expected changes.
    expect(editParams, isNotNull);
    final edit = editParams!.edit;
    if (expectDocumentChanges) {
      expect(edit.changes, isNull);
      expect(edit.documentChanges, isNotNull);
    } else {
      expect(edit.changes, isNotNull);
      expect(edit.documentChanges, isNull);
    }

    // Ensure applying the changes will give us the expected content.
    final contents = {
      mainFilePath: withoutMarkers(content),
    };

    if (expectDocumentChanges) {
      applyDocumentChanges(contents, edit.documentChanges!);
    } else {
      applyChanges(contents, edit.changes!);
    }
    expect(contents[mainFilePath], equals(expectedContent));
  }
}
