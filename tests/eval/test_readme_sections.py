"""
Golden dataset tests — verify the generated README contains required sections
and does not contain forbidden phrases.

Markers:
    smoke     — runs in CI (hello-world only, fast)
    extended  — nightly / manual (larger repos, slower)
"""
import json
import re

import pytest

GOLDEN_DIR = "tests/golden"


@pytest.mark.parametrize(
    "repo_slug",
    [
        pytest.param("hello-world",           marks=pytest.mark.smoke),
        pytest.param("fastapi",               marks=pytest.mark.extended),
        pytest.param("modelcontextprotocol",  marks=pytest.mark.extended),
    ],
)
def test_readme_has_required_sections(repo_slug, trigger_pipeline):
    """Generated README contains every section listed in expected_sections.json."""
    readme = trigger_pipeline(repo_slug)
    spec   = json.loads(open(f"{GOLDEN_DIR}/{repo_slug}/expected_sections.json").read())

    headings = re.findall(r"^#{1,3}\s+(.+)$", readme, re.MULTILINE)
    for section in spec["required_sections"]:
        assert any(section.lower() in h.lower() for h in headings), (
            f"Missing section '{section}' in {repo_slug} README.\n"
            f"Found headings: {headings}"
        )


@pytest.mark.parametrize(
    "repo_slug",
    [
        pytest.param("hello-world",           marks=pytest.mark.smoke),
        pytest.param("fastapi",               marks=pytest.mark.extended),
        pytest.param("modelcontextprotocol",  marks=pytest.mark.extended),
    ],
)
def test_readme_has_no_forbidden_phrases(repo_slug, trigger_pipeline):
    """Generated README does not expose the AI system prompt or refusal patterns."""
    readme = trigger_pipeline(repo_slug)
    spec   = json.loads(open(f"{GOLDEN_DIR}/{repo_slug}/expected_sections.json").read())

    for phrase in spec.get("forbidden_phrases", []):
        assert phrase not in readme, (
            f"Forbidden phrase '{phrase}' found in {repo_slug} README."
        )


@pytest.mark.parametrize(
    "repo_slug",
    [
        pytest.param("hello-world",           marks=pytest.mark.smoke),
        pytest.param("fastapi",               marks=pytest.mark.extended),
        pytest.param("modelcontextprotocol",  marks=pytest.mark.extended),
    ],
)
def test_readme_minimum_length(repo_slug, trigger_pipeline):
    """Generated README meets the minimum character count for the repo."""
    readme   = trigger_pipeline(repo_slug)
    spec     = json.loads(open(f"{GOLDEN_DIR}/{repo_slug}/expected_sections.json").read())
    min_len  = spec.get("min_length_chars", 200)

    assert len(readme) >= min_len, (
        f"{repo_slug} README is only {len(readme)} chars (minimum: {min_len})"
    )
