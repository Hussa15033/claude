#!/usr/bin/env python3
"""
Offline, dependency-free OpenAI-compatible mock LLM for the DTL GenAI framework.

It speaks the OpenAI Chat Completions wire format (POST /v1/chat/completions)
so the IRIS business operation can target it with the exact same request shape
it would send to api.openai.com -- only the host/port (and the lack of TLS)
differ. This lets the full generate -> compile -> verify -> regenerate loop be
demonstrated with NO API key and NO outbound network access.

The mock deliberately *scripts a self-correction curriculum* so the IRIS
regeneration loop is exercised:

  * It inspects the incoming transcript and counts how many "assistant" turns
    are already present (i.e. how many prior attempts the loop has made).
  * It infers which example scenario is in play by scanning the user content
    for the message type / DocType.
  * Attempt 1 (0 prior assistant turns)  -> returns a DTL that does NOT compile
                                            (an unterminated <assign>).
  * Attempt 2 (1 prior assistant turn)   -> returns a DTL that compiles + runs
                                            but mis-maps one field (drives the
                                            field-diff feedback branch).
  * Attempt 3+ (2+ prior assistant turns)-> returns the correct, verifying DTL.

The "correct" payloads are the reference transforms that were proven byte-exact
against the outputs/ files in a live IRIS for Health container.

Run:  python3 mock_llm.py --port 8085
Env:  MOCK_LLM_PORT overrides the port.
"""

import argparse
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


# ---------------------------------------------------------------------------
# Scripted DTL payloads per scenario. Each scenario has three stages keyed by
# the number of prior assistant turns: broken -> wrong-field -> correct.
# The class name is intentionally underscore-free (IRIS class names forbid '_').
# ---------------------------------------------------------------------------

def _wrap(class_name: str, transform_body: str) -> str:
    return (
        "```objectscript\n"
        f"Class {class_name} Extends Ens.DataTransformDTL "
        "[ DependsOn = EnsLib.HL7.Message ]\n"
        "{\n"
        'XData DTL [ XMLNamespace = "http://www.intersystems.com/dtl" ]\n'
        "{\n"
        f"{transform_body}\n"
        "}\n"
        "}\n"
        "```\n"
    )


SCENARIOS = {
    "ADT_A01": {
        "class": "DTL.Generated.AdtA01Forge",
        "src": "2.3:ADT_A01",
        "tgt": "2.5:ADT_A01",
        "rules": [
            {"index": 1, "rule": "Set MSH-3 (sending application) to EPIC.", "sourceQuote": "rename the sending application to EPIC", "inferred": False},
            {"index": 2, "rule": "Normalize facility code SITEA to 001 in MSH-4.", "sourceQuote": "normalize facility SITEA to 001", "inferred": False},
            {"index": 3, "rule": "Upgrade the HL7 version (MSH-12) from 2.3 to 2.5.", "sourceQuote": "upgrade the message to v2.5", "inferred": False},
            {"index": 4, "rule": "Set facility to 001 in PID-3.4 and PV1-3.4.", "sourceQuote": "across MSH/PID/PV1", "inferred": False},
        ],
        # Stage 0: BROKEN -- the first <assign> value attribute is never closed,
        # which yields a real compile error (#5xxx) with a line number.
        "broken": (
            "<transform sourceClass='EnsLib.HL7.Message' targetClass='EnsLib.HL7.Message' "
            "sourceDocType='2.3:ADT_A01' targetDocType='2.5:ADT_A01' create='copy' language='objectscript'>\n"
            "<assign value='\"EPIC' property='target.{MSH:3.1}' action='set'/>\n"
            "<assign value=$$$BADMACRO(x property='target.{MSH:4.1}' action='set'/>\n"
            "</transform>"
        ),
        # Stage 1: COMPILES + RUNS but wrong -- sets MSH-4 to the wrong facility
        # and forgets the version bump and PID/PV1 facility remaps.
        "wrong": (
            "<transform sourceClass='EnsLib.HL7.Message' targetClass='EnsLib.HL7.Message' "
            "sourceDocType='2.3:ADT_A01' targetDocType='2.5:ADT_A01' create='copy' language='objectscript'>\n"
            "<assign value='\"EPIC\"' property='target.{MSH:3.1}' action='set'/>\n"
            "<assign value='\"WRONGFAC\"' property='target.{MSH:4.1}' action='set'/>\n"
            "</transform>"
        ),
        # Stage 2: CORRECT -- proven byte-exact in the live container.
        "correct": (
            "<transform sourceClass='EnsLib.HL7.Message' targetClass='EnsLib.HL7.Message' "
            "sourceDocType='2.3:ADT_A01' targetDocType='2.5:ADT_A01' create='copy' language='objectscript'>\n"
            "<assign value='\"EPIC\"' property='target.{MSH:3.1}' action='set'/>\n"
            "<assign value='\"001\"' property='target.{MSH:4.1}' action='set'/>\n"
            "<assign value='\"2.5\"' property='target.{MSH:12}' action='set'/>\n"
            "<assign value='\"001\"' property='target.{PID:3(1).4}' action='set'/>\n"
            "<assign value='\"001\"' property='target.{PV1:3.4}' action='set'/>\n"
            "</transform>"
        ),
    },
    "ADT_A08": {
        "class": "DTL.Generated.AdtA08Forge",
        "src": "2.3:ADT_A01",  # A08 uses the ADT_A01 structure in 2.3
        "tgt": "2.5:ADT_A01",
        "rules": [
            {"index": 1, "rule": "Upgrade the HL7 version (MSH-12) from 2.3 to 2.5.", "sourceQuote": "upgrade to 2.5", "inferred": False},
            {"index": 2, "rule": "Map PID-8 administrative sex F->2 and M->1.", "sourceQuote": "map sex codes", "inferred": False},
        ],
        "broken": (
            "<transform sourceClass='EnsLib.HL7.Message' targetClass='EnsLib.HL7.Message' "
            "sourceDocType='2.3:ADT_A01' targetDocType='2.5:ADT_A01' create='copy' language='objectscript'>\n"
            "<assign value='\"2.5' property='target.{MSH:12}' action='set'/>\n"
            "</transform>"
        ),
        "wrong": (
            "<transform sourceClass='EnsLib.HL7.Message' targetClass='EnsLib.HL7.Message' "
            "sourceDocType='2.3:ADT_A01' targetDocType='2.5:ADT_A01' create='copy' language='objectscript'>\n"
            "<assign value='\"2.5\"' property='target.{MSH:12}' action='set'/>\n"
            "</transform>"
        ),
        "correct": (
            "<transform sourceClass='EnsLib.HL7.Message' targetClass='EnsLib.HL7.Message' "
            "sourceDocType='2.3:ADT_A01' targetDocType='2.5:ADT_A01' create='copy' language='objectscript'>\n"
            "<assign value='\"2.5\"' property='target.{MSH:12}' action='set'/>\n"
            "<if condition='source.{PID:8}=\"F\"'><true>"
            "<assign value='\"2\"' property='target.{PID:8}' action='set'/></true></if>\n"
            "<if condition='source.{PID:8}=\"M\"'><true>"
            "<assign value='\"1\"' property='target.{PID:8}' action='set'/></true></if>\n"
            "</transform>"
        ),
    },
    "ORU_R01": {
        "class": "DTL.Generated.OruR01Forge",
        "src": "2.3:ORU_R01",
        "tgt": "2.5:ORU_R01",
        "rules": [
            {"index": 1, "rule": "Set MSH-3 (sending application) to LIS.", "sourceQuote": "sending application LIS", "inferred": False},
            {"index": 2, "rule": "Set MSH-4 (facility) to GH.", "sourceQuote": "facility GH", "inferred": False},
            {"index": 3, "rule": "Upgrade the HL7 version (MSH-12) to 2.5.", "sourceQuote": "version 2.5", "inferred": False},
            {"index": 4, "rule": "Set facility GH in PID-3.4 (within the patient group).", "sourceQuote": "patient identifier facility", "inferred": False},
        ],
        "broken": (
            "<transform sourceClass='EnsLib.HL7.Message' targetClass='EnsLib.HL7.Message' "
            "sourceDocType='2.3:ORU_R01' targetDocType='2.5:ORU_R01' create='copy' language='objectscript'>\n"
            "<assign value='\"LIS\"' property='target.{MSH:3.1} action='set'/>\n"  # missing closing brace+quote
            "</transform"  # unterminated tag
        ),
        "wrong": (
            "<transform sourceClass='EnsLib.HL7.Message' targetClass='EnsLib.HL7.Message' "
            "sourceDocType='2.3:ORU_R01' targetDocType='2.5:ORU_R01' create='copy' language='objectscript'>\n"
            "<assign value='\"LIS\"' property='target.{MSH:3.1}' action='set'/>\n"
            "<assign value='\"2.5\"' property='target.{MSH:12}' action='set'/>\n"
            "</transform>"
        ),
        "correct": (
            "<transform sourceClass='EnsLib.HL7.Message' targetClass='EnsLib.HL7.Message' "
            "sourceDocType='2.3:ORU_R01' targetDocType='2.5:ORU_R01' create='copy' language='objectscript'>\n"
            "<assign value='\"LIS\"' property='target.{MSH:3.1}' action='set'/>\n"
            "<assign value='\"GH\"' property='target.{MSH:4.1}' action='set'/>\n"
            "<assign value='\"2.5\"' property='target.{MSH:12}' action='set'/>\n"
            "<assign value='\"GH\"' property='target.{PIDgrpgrp(1).PIDgrp.PID:3(1).4}' action='set'/>\n"
            "</transform>"
        ),
    },
}

# Order matters: check the more specific trigger (A08) before the generic ADT.
SCENARIO_MATCHERS = [
    ("ADT_A08", [r"ADT\^A08", r"ADT_A08", r"A08"]),
    ("ORU_R01", [r"ORU\^R01", r"ORU_R01", r"\bORU\b"]),
    ("ADT_A01", [r"ADT\^A01", r"ADT_A01", r"\bADT\b"]),
]

STAGE_ORDER = ["broken", "wrong", "correct"]


def detect_scenario(text: str) -> str:
    for name, patterns in SCENARIO_MATCHERS:
        for pat in patterns:
            if re.search(pat, text, re.IGNORECASE):
                return name
    return "ADT_A01"


def pick_stage(prior_assistant_turns: int) -> str:
    idx = min(prior_assistant_turns, len(STAGE_ORDER) - 1)
    return STAGE_ORDER[idx]


def _system_text(messages):
    return "\n".join(m.get("content", "") for m in messages if m.get("role") == "system")


def _last_user(messages):
    for m in reversed(messages):
        if m.get("role") == "user":
            return m.get("content", "")
    return ""


def _structure_json(scenario):
    """Reply for STEP 0 (spec structuring): an explicit rule list with provenance,
    as strict JSON, matching DTL.Util.PromptBuilder.SpecStructurePrompt's schema."""
    spec = SCENARIOS[scenario]
    rules = spec.get("rules", [
        {"index": 1, "rule": "Set MSH-3 (sending application).",
         "sourceQuote": "sending application", "inferred": False},
        {"index": 2, "rule": "Upgrade the HL7 version in MSH-12.",
         "sourceQuote": "version", "inferred": False},
    ])
    obj = {"title": "%s interface specification" % scenario,
           "rules": rules, "ambiguities": []}
    return json.dumps(obj)


def _concise_json(scenario):
    """Reply for the CONCISE-spec generation: rules grouped by message/segment type
    with provenance, matching PromptBuilder.ConciseSpecPrompt's schema."""
    spec = SCENARIOS[scenario]
    rules = spec.get("rules", [])
    items = [{"id": "g1i%d" % (i + 1), "rule": r["rule"],
              "sourceQuote": r.get("sourceQuote", ""), "inferred": r.get("inferred", False)}
             for i, r in enumerate(rules)]
    obj = {"title": "%s interface" % scenario,
           "groups": [{"type": "%s / MSH" % scenario, "items": items}],
           "ambiguities": [
               {"question": "Should the facility code be normalised in PID-3.4 as well as MSH-4?",
                "segment": "%s / MSH" % scenario,
                "options": ["Normalise the facility in both MSH-4 and PID-3.4",
                            "Normalise MSH-4 only; leave PID-3.4 unchanged"]},
               {"question": "Is the version upgrade (2.3 -> 2.5) mandatory for all message types?",
                "segment": "%s / MSH" % scenario,
                "options": ["Upgrade MSH-12 to 2.5 for every message",
                            "Only upgrade ADT messages",
                            "Leave the version unchanged"]},
           ]}
    return json.dumps(obj)


def _concise_verify_json():
    """Reply for the concise-spec audit: the mock concise spec is faithful+complete."""
    return json.dumps({"complete": True, "faithful": True, "score": 1.0,
                       "missing": [], "hallucinated": [], "notes": "Concise spec matches the original."})


def _judge_json(messages):
    """Reply for the LLM-as-judge: decide if the PRODUCED OUTPUT meets the spec.
    The mock approves only the final/correct stage. It infers 'is this the correct
    candidate' by whether the produced output in the prompt looks fully transformed
    (contains the version bump 2.5 AND a facility/app remap) — good enough to drive
    the loop offline."""
    last = _last_user(messages)
    # The judge prompt embeds INPUT and (last) PRODUCED OUTPUT. Split on the LAST
    # occurrence of the label so we look at the actual output block, not the
    # instruction sentence that also mentions "PRODUCED OUTPUT". The 'wrong' stage
    # misses the version bump / facility remaps; the 'correct' stage has them.
    out_section = last.rsplit("PRODUCED OUTPUT", 1)[-1]
    conforms = ("2.5" in out_section) and (("001" in out_section) or ("GH" in out_section) or ("\"2\"" in out_section) or ("|2|" in out_section))
    if conforms:
        obj = {"conforms": True, "score": 1.0, "violations": [], "notes": "All spec rules applied."}
    else:
        obj = {"conforms": False, "score": 0.5,
               "violations": [{"rule": "Apply all specified field remaps and the version bump",
                               "detail": "Output is missing one or more required changes (facility/app remap or MSH-12 version).",
                               "severity": "HIGH"}],
               "notes": "Incomplete transformation."}
    return json.dumps(obj)


def build_completion(messages):
    user_text = "\n".join(
        m.get("content", "") for m in messages if m.get("role") == "user"
    )
    sys_text = _system_text(messages)
    last_user = _last_user(messages)
    scenario = detect_scenario(user_text)

    # --- Route by call type (the prompts are self-describing). ---
    # CONCISE-spec audit -> faithful/complete verdict (check before generation: it
    # mentions both "hallucinated" and "CONCISE SPECIFICATION").
    if ("hallucinated" in last_user) and ("CONCISE SPECIFICATION" in last_user):
        return _concise_verify_json(), {"scenario": scenario, "stage": "concise-verify"}
    # CONCISE-spec generation -> grouped JSON with provenance.
    if ("groups" in last_user) and ("GROUPED BY" in last_user):
        return _concise_json(scenario), {"scenario": scenario, "stage": "concise"}
    # STEP 0: spec structuring -> strict JSON rule list.
    if ("STRICT JSON" in last_user) and ("rules" in last_user) and ("sourceQuote" in last_user):
        return _structure_json(scenario), {"scenario": scenario, "stage": "structure"}
    # LLM-as-judge conformance -> strict JSON verdict.
    if ("conforms" in last_user) and ("violations" in last_user) and ("PRODUCED OUTPUT" in last_user):
        return _judge_json(messages), {"scenario": scenario, "stage": "judge"}
    # PLAN step -> a short markdown plan (not a class). Detect the plan instruction.
    if ("SHORT PLAN" in last_user) or ("numbered markdown list" in last_user):
        spec = SCENARIOS[scenario]
        plan = "1. " + "\n2. ".join(
            r["rule"] for r in spec.get("rules", [{"rule": "Apply the specified field changes."}])
        )
        return plan, {"scenario": scenario, "stage": "plan"}

    # --- BUILD curriculum: count only BUILD assistant turns (skip the structuring
    #     reply + any [spec-conformance judge] aux turns) so broken->wrong->correct
    #     still progresses correctly through the new flow. ---
    build_assistant = sum(
        1 for m in messages
        if m.get("role") == "assistant"
        and not m.get("content", "").startswith("{")          # structuring/judge JSON
        and "[spec-conformance judge]" not in m.get("content", "")
        and "<transform" in m.get("content", "")              # only count DTL replies
    )
    stage = pick_stage(build_assistant)
    spec = SCENARIOS[scenario]
    body = spec[stage]
    content = _wrap(spec["class"], body)
    meta = {"scenario": scenario, "stage": stage, "prior_assistant_turns": build_assistant}
    return content, meta


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send_json(self, status, obj):
        payload = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        # Minimal health + models endpoints.
        if self.path.rstrip("/") in ("/health", "/healthz"):
            return self._send_json(200, {"status": "ok"})
        if self.path.rstrip("/") == "/v1/models":
            return self._send_json(200, {
                "object": "list",
                "data": [{"id": "mock-dtl-gpt", "object": "model", "owned_by": "mock"}],
            })
        return self._send_json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            req = json.loads(raw.decode("utf-8") or "{}")
        except Exception as e:
            return self._send_json(400, {"error": {"message": f"bad json: {e}"}})

        if not self.path.rstrip("/").endswith("/chat/completions"):
            return self._send_json(404, {"error": {"message": f"unknown path {self.path}"}})

        messages = req.get("messages", [])
        model = req.get("model", "mock-dtl-gpt")
        content, meta = build_completion(messages)

        # Log to stderr so the demo is observable.
        sys.stderr.write(
            f"[mock_llm] scenario={meta.get('scenario')} stage={meta.get('stage')} "
            f"prior_assistant_turns={meta.get('prior_assistant_turns', '-')}\n"
        )
        sys.stderr.flush()

        prompt_tokens = sum(len(m.get("content", "")) for m in messages) // 4
        completion_tokens = len(content) // 4
        resp = {
            "id": "chatcmpl-mock-0001",
            "object": "chat.completion",
            "created": 1700000000,
            "model": model,
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": content},
                    "finish_reason": "stop",
                }
            ],
            "usage": {
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "total_tokens": prompt_tokens + completion_tokens,
            },
            # Non-standard echo of what the mock decided (handy for the demo).
            "x_mock": meta,
        }
        return self._send_json(200, resp)

    def log_message(self, fmt, *args):  # silence default access logging
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=int(os.environ.get("MOCK_LLM_PORT", "8085")))
    ap.add_argument("--host", default="0.0.0.0")
    args = ap.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    sys.stderr.write(f"[mock_llm] listening on {args.host}:{args.port} (POST /v1/chat/completions)\n")
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
