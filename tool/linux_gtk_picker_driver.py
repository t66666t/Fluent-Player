"""Confirm the real GTK Open button through its accessibility interface."""
from pathlib import Path
import sys
import time

import pyatspi


def descendants(node, depth=0):
    if depth > 16:
        return
    yield node
    try:
        for child in node:
            yield from descendants(child, depth + 1)
    except (LookupError, RuntimeError):
        return


sample = str(Path(sys.argv[1]).resolve())
for attempt in range(30):
    dialogs = [node for node in descendants(pyatspi.Registry.getDesktop(0))
               if node.name == 'Fluent file dialog smoke']
    if not dialogs:
        if attempt:
            print('GTK chooser closed after Open', flush=True)
            raise SystemExit(0)
        time.sleep(0.5)
        continue
    nodes = list(descendants(dialogs[0]))
    if attempt == 0:
        print('GTK controls: ' + repr([(node.getRoleName(), node.name)
                                      for node in nodes if node.name][:50]), flush=True)
    for node in nodes:
        state = node.getState()
        if not state.contains(pyatspi.STATE_SHOWING):
            continue
        if node.getRole() in (pyatspi.ROLE_TEXT, pyatspi.ROLE_ENTRY):
            try:
                text = node.queryText().getText(0, -1)
                if state.contains(pyatspi.STATE_FOCUSED) or 'location' in node.name.lower():
                    if text != sample:
                        node.queryEditableText().setTextContents(sample)
                        print('GTK location set to the generated sample', flush=True)
            except (NotImplementedError, RuntimeError):
                pass
    for node in nodes:
        if node.getRole() != pyatspi.ROLE_PUSH_BUTTON or node.name.replace('_', '') != 'Open':
            continue
        if node.getState().contains(pyatspi.STATE_SENSITIVE):
            action = node.queryAction()
            for index in range(action.nActions):
                if action.getName(index) in ('click', 'activate', 'press'):
                    print('Activating the GTK Open button', flush=True)
                    action.doAction(index)
                    break
    time.sleep(0.5)
raise RuntimeError('GTK chooser did not accept the generated sample')
