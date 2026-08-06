#!/usr/bin/env python3
"""Check format-argument validation, including translated bulk-delete messages."""

import unittest

from check_localizations import format_arguments


# Exercise format-argument compatibility without loading app translations or user settings.
class FormatArgumentsTests(unittest.TestCase):
    # test_reordered_delete_message(self): Allow translated messages to reorder
    # arguments while preserving their types.
    def test_reordered_delete_message(self):
        # Passing a count to %@ can crash Foundation's String(format:).
        english = format_arguments("Delete %d items from %@?")
        self.assertNotEqual(english, format_arguments("%@에서 %d개 항목을 삭제할까요?"))
        self.assertEqual(english, format_arguments("%2$@에서 %1$d개 항목을 삭제할까요?"))

    # test_repeated_numbered_argument(self): A numbered argument may be reused
    # without consuming another argument position.
    def test_repeated_numbered_argument(self):
        self.assertEqual(format_arguments("%1$@ → %1$@"), {1: "@"})

    # test_literal_percent(self): Escaped percent signs must not count as format
    # arguments.
    def test_literal_percent(self):
        self.assertEqual(format_arguments("100%%; %@"), {1: "@"})

    # test_numeric_widths_and_types(self): Preserve numeric types while ignoring
    # field width and decimal precision.
    def test_numeric_widths_and_types(self):
        self.assertEqual(format_arguments("%08d %.2f %lld"), {1: "d", 2: "f", 3: "lld"})
        self.assertNotEqual(format_arguments("%ld"), format_arguments("%d"))

    # test_missing_or_added_argument(self): Detect argument removal or addition
    # as a signature mismatch.
    def test_missing_or_added_argument(self):
        self.assertNotEqual(format_arguments("%@"), format_arguments(""))
        self.assertNotEqual(format_arguments("%@"), format_arguments("%@ %@"))

    # test_ambiguous_arguments(self): Reject ambiguous numbering and conflicting
    # types for a repeated position.
    def test_ambiguous_arguments(self):
        # Cover mixed numbering, type conflicts, and invalid zero-based positions.
        for text in ("%1$@ %d", "%1$@ %1$d", "%0$@"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                format_arguments(text)


# Run these unit checks only on direct invocation.
if __name__ == "__main__":
    unittest.main()
