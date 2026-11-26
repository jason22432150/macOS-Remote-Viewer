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
        '    g_free(password);\n    return ret;',
        '    mrv_secure_string_free_tag(password, "MRV_NATIVE_AUTH_TICKET_WIPED");\n    return ret;')
    text = replace_once(text,
        '        memset(encrypted, 0, nRSASize);',
        '        mrv_secure_clear(encrypted, nRSASize);')
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
        '    in->data = mrv_receive_budget_alloc(&mrv_wire_budget, (gsize)msg_size, &in->mrv_wire_charge);\n'
        '    if (!in->data) {\n'
        '        mrv_receive_test_trace("MRV_NATIVE_WIRE_BUDGET_OR_ALLOC_REJECTED");\n'
        '        c->event = SPICE_CHANNEL_ERROR_IO;\n'
        '        c->has_error = TRUE;\n'
        '        goto end;\n'
        '    }')
    # Submessages borrow parent->data and retain the parent. Only the
    # final reference to an owning root may free its allocation/charge.
    text = replace_once(text,
        '    if (in->parent) {\n'
        '        spice_msg_in_unref(in->parent);\n'
        '    } else {\n'
        '        g_free(in->data);\n'
        '    }',
        '    if (in->parent) {\n'
        '        spice_msg_in_unref(in->parent);\n'
        '    } else {\n'
        '        mrv_receive_budget_clear(&mrv_wire_budget, &in->data, &in->mrv_wire_charge);\n'
        '    }')
    text = replace_once(text,
        '    spice_msg_in_ref(parent);\n    return in;',
        '    spice_msg_in_ref(parent);\n'
        '    parent->mrv_wire_has_child = TRUE;\n'
        '    mrv_receive_test_trace("MRV_NATIVE_WIRE_CHILD_RETAINED");\n'
        '    return in;')
    text = replace_once(text,
        '    if (in->parent) {\n'
        '        spice_msg_in_unref(in->parent);\n'
        '    } else {\n'
        '        mrv_receive_budget_clear(&mrv_wire_budget, &in->data, &in->mrv_wire_charge);\n'
        '    }',
        '    if (in->parent) {\n'
        '        mrv_receive_test_trace("MRV_NATIVE_WIRE_CHILD_RELEASED");\n'
        '        spice_msg_in_unref(in->parent);\n'
        '    } else {\n'
        '        mrv_receive_budget_clear(&mrv_wire_budget, &in->data, &in->mrv_wire_charge);\n'
        '        if (in->mrv_wire_has_child)\n'
        '            mrv_receive_test_trace("MRV_NATIVE_WIRE_PARENT_RELEASED");\n'
        '    }')
    # Validate the entire list before taking any borrowed submessage reference.
    text = replace_once(text,
        '        sub_list = (SpiceSubMessageList *)(in->data + sub_list_offset);\n'
        '        for (i = 0; i < sub_list->size; i++) {',
        '        if (sub_list_offset < 0 || (gsize)sub_list_offset > (gsize)msg_size ||\n'
        '            (gsize)msg_size - (gsize)sub_list_offset < G_STRUCT_OFFSET(SpiceSubMessageList, sub_messages))\n'
        '            goto reject_sublist;\n'
        '        sub_list = (SpiceSubMessageList *)(in->data + sub_list_offset);\n'
        '        if ((gsize)sub_list->size > ((gsize)msg_size - (gsize)sub_list_offset -\n'
        '            G_STRUCT_OFFSET(SpiceSubMessageList, sub_messages)) / sizeof(sub_list->sub_messages[0]))\n'
        '            goto reject_sublist;\n'
        '        for (i = 0; i < sub_list->size; i++) {\n'
        '            gsize off = sub_list->sub_messages[i];\n'
        '            if (off > (gsize)msg_size || (gsize)msg_size - off < sizeof(SpiceSubMessage))\n'
        '                goto reject_sublist;\n'
        '            sub = (SpiceSubMessage *)(in->data + off);\n'
        '            if ((gsize)sub->size > (gsize)msg_size - off - sizeof(SpiceSubMessage))\n'
        '                goto reject_sublist;\n'
        '        }\n'
        '        for (i = 0; i < sub_list->size; i++) {')
    text = replace_once(text,
        '                           c->name, spice_header_get_msg_type(sub_in->header, c->use_mini_header));\n'
        '                goto end;',
        '                           c->name, spice_header_get_msg_type(sub_in->header, c->use_mini_header));\n'
        '                spice_msg_in_unref(sub_in);\n'
        '                mrv_receive_test_trace("MRV_NATIVE_WIRE_CHILD_PARSE_REJECTED");\n'
        '                c->event = SPICE_CHANNEL_ERROR_IO;\n'
        '                c->has_error = TRUE;\n'
        '                goto end;')
    text = replace_once(text,
        '    /* ack message */',
        '    goto sublist_checked;\n'
        'reject_sublist:\n'
        '    mrv_receive_test_trace("MRV_NATIVE_WIRE_SUBLIST_REJECTED");\n'
        '    c->event = SPICE_CHANNEL_ERROR_IO;\n'
        '    c->has_error = TRUE;\n'
        '    goto end;\n'
        'sublist_checked:\n'
        '    /* ack message */')
    if ('g_free(in->data)' in text or
            text.count('mrv_receive_budget_alloc(&mrv_wire_budget,') != 1 or
            text.count('mrv_receive_budget_clear(&mrv_wire_budget,') != 1):
        raise ValueError("wire receive budget ownership anchors changed")
    return ('#include "mrv-receive-limits.h"\n'
            'static MRVReceiveBudget mrv_wire_budget = { .limit = MRV_WIRE_TOTAL_MAX };\n' + text)


def patch_private_header(text):
    return replace_once(text,
        '    uint8_t               *data;\n'
        '    int                   dpos;',
        '    uint8_t               *data;\n'
        '    gsize                 mrv_wire_charge; /* owning root only */\n'
        '    gboolean              mrv_wire_has_child;\n'
        '    int                   dpos;')


def patch_agent(text):
    text = replace_once(text,
        '    guint8                      *agent_msg_data;',
        '    guint8                      *agent_msg_data;\n'
        '    gsize                       mrv_agent_charge;')
    # All original ownership-release sites: finalization, agent reset and
    # successful reconstruction. Reject path below uses the same helper.
    text = replace_once(text,
        '    g_free(c->agent_msg_data);\n    agent_free_msg_queue',
        '    mrv_receive_budget_clear(&mrv_agent_budget, &c->agent_msg_data, &c->mrv_agent_charge);\n'
        '    agent_free_msg_queue')
    text = replace_once(text,
        '    g_clear_pointer(&c->agent_msg_data, g_free);',
        '    mrv_receive_budget_clear(&mrv_agent_budget, &c->agent_msg_data, &c->mrv_agent_charge);')
    text = replace_once(text,
        '        g_free(c->agent_msg_data);\n        c->agent_msg_data = NULL;',
        '        mrv_receive_budget_clear(&mrv_agent_budget, &c->agent_msg_data, &c->mrv_agent_charge);')
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
        '            c->agent_msg_data = mrv_receive_budget_alloc(&mrv_agent_budget, c->agent_msg.size, &c->mrv_agent_charge);\n'
        '            if (!c->agent_msg_data) {\n'
        '                mrv_receive_test_trace("MRV_NATIVE_AGENT_BUDGET_OR_ALLOC_REJECTED");\n'
        '                return FALSE;\n'
        '            }')
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
        '            main_agent_handle_msg(channel, msg, msg->data);',
        '            main_agent_handle_msg(channel, msg, msg->data);\n'
        '            mrv_receive_test_trace("MRV_NATIVE_AGENT_DIRECT_DELIVERED");')
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
        '    mrv_receive_budget_clear(&mrv_agent_budget, &c->agent_msg_data, &c->mrv_agent_charge);\n'
        '    c->agent_msg_pos = 0;\n'
        '    spice_channel_disconnect(channel, SPICE_CHANNEL_ERROR_IO);\n'
        '}')
    # Fail if upstream ownership sites have changed or remain unaccounted.
    if ('g_free(c->agent_msg_data)' in text or
            'g_clear_pointer(&c->agent_msg_data, g_free)' in text or
            text.count('mrv_receive_budget_clear(&mrv_agent_budget, &c->agent_msg_data, &c->mrv_agent_charge)') != 4 or
            text.count('mrv_receive_budget_alloc(&mrv_agent_budget, c->agent_msg.size, &c->mrv_agent_charge)') != 1):
        raise ValueError("agent receive budget ownership anchors changed")
    return ('#include "mrv-receive-limits.h"\n'
            'static MRVReceiveBudget mrv_agent_budget = { .limit = MRV_AGENT_TOTAL_MAX };\n' + text)


def replace_count(text, old, new, expected):
    if text.count(old) != expected:
        raise ValueError(f"upstream ownership anchor mismatch: {old!r}")
    return text.replace(old, new)


def patch_session(text):
    for name in ("host", "username", "password"):
        text = replace_count(text, f"g_free(s->{name});",
            f'mrv_secure_string_free_tag(s->{name}, "MRV_NATIVE_SESSION_SECRET_WIPED");', 3)
        text = replace_once(text, f"g_free({name});",
            f'mrv_secure_string_free_tag({name}, "MRV_NATIVE_SESSION_SECRET_WIPED");')
    # The parser splits the mutable URI in place. Preserve its original
    # extent, including all bytes beyond inserted NUL terminators.
    text = replace_once(text, '    uri = g_strdup(original_uri);',
        '    gsize mrv_uri_bytes = strlen(original_uri) + 1;\n'
        '    uri = g_strdup(original_uri);')
    text = replace_count(text, 'g_free(uri);',
        'mrv_secure_buffer_free(uri, mrv_uri_bytes, "MRV_NATIVE_SESSION_URI_COPY_WIPED");', 2)
    return '#include "mrv-receive-limits.h"\n' + text


def patch_uri(text):
    for name in ("user", "password"):
        text = replace_once(text, f'g_clear_pointer(&self->{name}, g_free);',
            f'g_clear_pointer(&self->{name}, mrv_secure_proxy_string_free);')
        text = replace_once(text,
            f'    g_free(self->{name});\n    self->{name} = g_strdup({name});',
            f'    gchar *replacement = g_strdup({name});\n'
            f'    mrv_secure_proxy_string_free(self->{name});\n'
            f'    self->{name} = replacement;')
    text = replace_once(text, '    uri = dup = g_strdup(_uri);',
        '    gsize mrv_uri_bytes = strlen(_uri) + 1;\n'
        '    uri = dup = g_strdup(_uri);')
    text = replace_once(text, '    g_free(dup);',
        '    mrv_secure_buffer_free(dup, mrv_uri_bytes, "MRV_NATIVE_PROXY_URI_COPY_WIPED");')
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
    changes = {audit.FILES[0]: patch_agent, audit.FILES[1]: patch_channel,
               audit.FILES[2]: patch_private_header, audit.FILES[3]: patch_session,
               audit.FILES[4]: patch_uri}
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
