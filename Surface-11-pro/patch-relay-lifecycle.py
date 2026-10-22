#!/usr/bin/env python3
"""Guard the pinned relay's native-input lifetime and backend errors."""
from pathlib import Path
import sys


def patch(source):
    def replace(old, new):
        nonlocal source
        if source.count(old) != 1:
            raise ValueError(f'Unexpected relay lifecycle source around {old!r}')
        source = source.replace(old, new)
    replace('static GMainLoop *loop = NULL;',
            'static GMainLoop *loop = NULL;\nstatic gboolean backend_failed = FALSE;')
    replace('''  if (input_pipeline != NULL)
    gst_element_set_state (input_pipeline, GST_STATE_NULL);''', '''  if (input_pipeline != NULL) {
    gst_element_set_state (input_pipeline, GST_STATE_NULL);
    if (input_bus_watch_id != 0) {
      g_source_remove (input_bus_watch_id);
      input_bus_watch_id = 0;
    }
    gst_object_unref (input_pipeline);
    input_pipeline = NULL;
  }''')
    replace('''      gst_element_set_state (pipeline, GST_STATE_NULL);
      break;''', '''      gst_element_set_state (pipeline, GST_STATE_NULL);
      backend_failed = TRUE;
      g_main_loop_quit (loop);
      break;''')
    replace('''  gst_element_set_state (input_pipeline_get (), GST_STATE_PLAYING);''', '''  GstElement *input = input_pipeline_get ();
  if (input == NULL || gst_element_set_state (input, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
    backend_failed = TRUE;
    g_main_loop_quit (loop);
  }''')
    ending = '\n  return 0;\n}\n'
    if not source.endswith(ending):
        raise ValueError('Unexpected relay main() ending')
    return source[:-len(ending)] + '\n  return backend_failed ? 1 : 0;\n}\n'


if __name__ == '__main__':
    try:
        path = Path(sys.argv[1])
        path.write_text(patch(path.read_text()))
    except (OSError, ValueError, IndexError) as exc:
        raise SystemExit(str(exc))
