#!/usr/bin/env python3
import unittest
from route_issue import answer, labels_for, load_routing


class IssueRoutingTests(unittest.TestCase):
    def setUp(self):
        self.routing = load_routing()

    def test_every_form_area_routes_to_known_labels(self):
        for area, labels in self.routing['areas'].items():
            self.assertEqual(labels_for('### Area\n\n' + area + '\n\n### Steps\nAnything', self.routing), sorted(labels))

    def test_multiple_choices_including_commas_and_crlf(self):
        choices = list(self.routing['areas'])[:4]
        expected = sorted(set(label for c in choices for label in self.routing['areas'][c]))
        self.assertEqual(labels_for('### Area\r\n' + ', '.join(choices) + '\r\n### Other\r\nSettings', self.routing), expected)

    def test_missing_answer_or_arbitrary_label_cannot_inject_labels(self):
        for text in ['', '### Area\n_No response_', '### Area\n$(rm -rf /)', '### Other\nSettings']:
            self.assertEqual(labels_for(text, self.routing), [])

    def test_heading_stops_at_the_next_field(self):
        self.assertEqual(answer('### Area\nSettings\n### Other\nChat', 'Area'), 'Settings')


if __name__ == '__main__':
    unittest.main()
