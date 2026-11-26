#!/usr/bin/env python3
"""Generate a review-only receive-limit candidate from the SHA-verified upstream archive."""
import argparse
import difflib
import hashlib
import importlib.util
import json
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("audit_spice_source", HERE / "audit-spice-source.py")
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"upstream anchor mismatch: {old[:100]!r}")
    return text.replace(old, new, 1)


def patch_channel(text):
    text = replace_once(text,
        '    if (c->peer_hdr.size < sizeof(*c->peer_msg)) {',
        '    if (!mrv_link_size_allowed(c->peer_hdr.size)) {\n'
        '        mrv_receive_test_trace("MRV_NATIVE_LINK_LIMIT_REJECTED");\n'
        '        goto error;\n'
        '    }\n'
        '    if (c->peer_hdr.size < sizeof(*c->peer_msg)) {')
    text = replace_once(text, '    c->peer_msg = g_malloc0(c->peer_hdr.size);',
                        '    c->peer_msg = g_try_malloc0(c->peer_hdr.size);')
    text = replace_once(text,
        '    SpiceMsgIn *in;\n    int msg_size;\n    int msg_type;',
        '    SpiceMsgIn *in;\n    guint32 wire_size;\n    int msg_size;\n    int msg_type;')
    text = replace_once(text,
        '    msg_size = spice_header_get_msg_size(in->header, c->use_mini_header);',
        '    wire_size = spice_header_get_msg_size(in->header, c->use_mini_header);\n'
        '    if (!mrv_wire_size_allowed(wire_size)) {\n'
        '        mrv_receive_test_trace("MRV_NATIVE_WIRE_LIMIT_REJECTED");\n'
        '        c->event = SPICE_CHANNEL_ERROR_IO;\n'
        '        c->has_error = TRUE;\n'
        '        goto end;\n'
        '    }\n'
        '    msg_size = (int)wire_size;')
    text = replace_once(text, '    in->data = g_malloc0(msg_size);',
        '    in->data = g_try_malloc0(MAX(msg_size, 1));\n'
        '    if (!in->data) {\n'
        '        c->event = SPICE_CHANNEL_ERROR_IO;\n'
        '        c->has_error = TRUE;\n'
        '        goto end;\n'
        '    }')
    return '#include "mrv-receive-limits.h"\n' + text


def patch_agent(text):
    text = replace_once(text,
        'static void main_handle_agent_data_msg(SpiceChannel* channel, int* msg_size, guchar** msg_pos)',
        'static gboolean main_handle_agent_data_msg(SpiceChannel* channel, int* msg_size, guchar** msg_pos)')
    text = replace_once(text,
        '            g_return_if_fail(c->agent_msg_data == NULL);\n'
        '            c->agent_msg_data = g_malloc0(c->agent_msg.size);',
        '            if (!mrv_agent_size_allowed(c->agent_msg.size)) {\n'
        '                mrv_receive_test_trace("MRV_NATIVE_AGENT_FRAGMENT_LIMIT_REJECTED");\n'
        '                return FALSE;\n'
        '            }\n'
        '            if (c->agent_msg_data != NULL)\n'
        '                return FALSE;\n'
        '            c->agent_msg_data = g_try_malloc0(MAX(c->agent_msg.size, 1u));\n'
        '            if (!c->agent_msg_data)\n'
        '                return FALSE;')
    text = replace_once(text,
        '        memcpy(c->agent_msg_data + c->agent_msg_pos - sizeof(VDAgentMessage), *msg_pos, n);',
        '        if (n > 0)\n'
        '            memcpy(c->agent_msg_data + c->agent_msg_pos - sizeof(VDAgentMessage), *msg_pos, n);')
    text = replace_once(text,
        '        main_agent_handle_msg(channel, &c->agent_msg, c->agent_msg_data);',
        '        main_agent_handle_msg(channel, &c->agent_msg, c->agent_msg_data);\n'
        '        mrv_receive_test_trace("MRV_NATIVE_AGENT_REASSEMBLED");')
    text = replace_once(text,
        '        c->agent_msg_pos = 0;\n    }\n}\n\n/* coroutine context */\nstatic void main_handle_agent_data(',
        '        c->agent_msg_pos = 0;\n    }\n    return TRUE;\n}\n\n/* coroutine context */\nstatic void main_handle_agent_data(')
    text = replace_once(text,
        '    /* shortcut to avoid extra message allocation & copy if possible */\n'
        '    if (c->agent_msg_pos == 0) {',
        '    data = spice_msg_in_raw(in, &len);\n'
        '    /* shortcut only after verifying the complete agent header is present */\n'
        '    if (c->agent_msg_pos == 0 && len >= (int)sizeof(VDAgentMessage)) {')
    text = replace_once(text,
        '        msg = spice_msg_in_raw(in, &len);\n'
        '        msg_size = msg->size;\n\n'
        '        if (msg_size + sizeof(VDAgentMessage) == len) {',
        '        msg = (VDAgentMessage *)data;\n'
        '        msg_size = msg->size;\n'
        '        if (!mrv_agent_size_allowed(msg_size)) {\n'
        '            mrv_receive_test_trace("MRV_NATIVE_AGENT_DIRECT_LIMIT_REJECTED");\n'
        '            goto reject;\n'
        '        }\n\n'
        '        if (msg_size == (guint)(len - sizeof(VDAgentMessage))) {')
    text = replace_once(text,
        '    data = spice_msg_in_raw(in, &len);\n'
        '    while (len > 0) {\n'
        '        main_handle_agent_data_msg(channel, &len, &data);\n'
        '    }\n}',
        '    while (len > 0) {\n'
        '        if (!main_handle_agent_data_msg(channel, &len, &data))\n'
        '            goto reject;\n'
        '    }\n'
        '    return;\n\n'
        'reject:\n'
        '    g_clear_pointer(&c->agent_msg_data, g_free);\n'
        '    c->agent_msg_pos = 0;\n'
        '    spice_channel_disconnect(channel, SPICE_CHANNEL_ERROR_IO);\n'
        '}')
    return '#include "mrv-receive-limits.h"\n' + text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audit", required=True, type=Path)
    args = parser.parse_args()
    with (HERE / "lockfile.toml").open("rb") as handle:
        lock = tomllib.load(handle)["spice_gtk"]
    version = lock["version"].split("_", 1)[0]
    archive = (args.audit / f"spice-gtk-{version}.tar.xz").read_bytes()
    audit.verify_digest(archive, lock["upstream_sha256"])
    sources = audit.read_source_files(archive, version)
    changes = {audit.FILES[0]: patch_agent, audit.FILES[1]: patch_channel}
    diffs = []
    hashes = {}
    for name, body in sources.items():
        old = body.decode("utf-8")
        new = changes[name](old)
        diffs.extend(difflib.unified_diff(old.splitlines(keepends=True),
                     new.splitlines(keepends=True), "a/" + name, "b/" + name))
        hashes[name] = hashlib.sha256(new.encode("utf-8")).hexdigest()
    name = "src/mrv-receive-limits.h"
    header = (HERE / "spice-receive-limits.h").read_text()
    diffs.extend(difflib.unified_diff([], header.splitlines(keepends=True), "/dev/null", "b/" + name))
    hashes[name] = hashlib.sha256(header.encode("utf-8")).hexdigest()
    (args.audit / "receive-limits-candidate.patch").write_text("".join(diffs))
    (args.audit / "candidate.json").write_text(json.dumps({
        "scope": "review-only; not built or linked into production",
        "upstream_sha256": lock["upstream_sha256"],
        "patched_file_sha256": hashes,
    }, indent=2) + "\n")
    print("MRV_SPICE_RECEIVE_CANDIDATE_APPLIED", flush=True)


if __name__ == "__main__":
    main()
