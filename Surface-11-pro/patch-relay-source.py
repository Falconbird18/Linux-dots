#!/usr/bin/env python3
"""Adapt the pinned upstream relay to the loopback writer and recoverable lifecycle."""
from pathlib import Path
import sys
p = Path(sys.argv[1]); s = p.read_text()
old = '#define V4L2_EVENT_PRI_CLIENT_USAGE  V4L2_EVENT_PRIVATE_START'
new = '#define V4L2_EVENT_PRI_CLIENT_USAGE (V4L2_EVENT_PRIVATE_START + 0x08E00000 + 1)'
if s.count(old) != 1:
    raise SystemExit('Unexpected relay source; refusing an unverified event API change.')
s = s.replace(old, new)
# The upstream idle transition checks input_pipeline twice; check the splash
# object before changing its state instead.
s = s.replace('if (input_pipeline != NULL)\n    gst_element_set_state (splash_pipeline,',
              'if (splash_pipeline != NULL)\n    gst_element_set_state (splash_pipeline,')
# On output failure before any client opens a camera, upstream cleanup may
# reference a nonexistent input pipeline/watch. Guard only those teardown calls.
for variable in ['input_bus_watch_id', 'output_bus_watch_id', 'splash_bus_watch_id']:
    old = f'  g_source_remove ({variable});'
    new = f'  if ({variable} != 0)\n    g_source_remove ({variable});'
    if s.count(old) != 1:
        raise SystemExit(f'Unexpected relay cleanup for {variable}')
    s = s.replace(old, new)
for variable in ['input_pipeline', 'splash_pipeline']:
    old = (f'  gst_element_set_state ({variable}, GST_STATE_NULL);\n'
           f'  gst_object_unref (GST_OBJECT ({variable}));')
    new = (f'  if ({variable} != NULL) {{\n'
           f'    gst_element_set_state ({variable}, GST_STATE_NULL);\n'
           f'    gst_object_unref (GST_OBJECT ({variable}));\n  }}')
    if s.count(old) != 1:
        raise SystemExit(f'Unexpected relay cleanup for {variable}')
    s = s.replace(old, new)
# Use our direct writer instead of GStreamer's unimplemented rw sink. Keep
# the upstream client-usage watch on the same descriptor used to write frames.
def replace_once(old, new):
    global s
    if s.count(old) != 1:
        raise SystemExit(f'Unexpected relay source around {old!r}')
    s = s.replace(old, new)
replace_once('static gboolean opt_background', '#include "loopback-writer.h"\n\nstatic gboolean opt_background')
replace_once('g_object_get (v4l2sink, "device-fd", &fd, NULL);', 'fd = loopback_fd;')
replace_once('"v4l2sink");', '"loopback-writer");')
replace_once('  gst_object_ref_sink (pipeline);\n\n  clock =',
             '  gst_object_ref_sink (pipeline);\n'
             '  if (!loopback_writer_attach (pipeline)) {\n'
             '    gst_object_unref (pipeline);\n    return NULL;\n  }\n\n  clock =')
replace_once('  gst_element_set_state (output_pipeline, GST_STATE_PLAYING);',
             '  if (output_pipeline == NULL) return 1;\n'
             '  gst_element_set_state (output_pipeline, GST_STATE_PLAYING);')
replace_once('  g_main_loop_unref (loop);',
             '  if (v4l2_event_poll_id != 0) g_source_remove (v4l2_event_poll_id);\n'
             '  if (loopback_fd >= 0) close (loopback_fd);\n'
             '  g_main_loop_unref (loop);')
p.write_text(s)
