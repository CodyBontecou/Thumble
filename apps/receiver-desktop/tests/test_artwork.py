import unittest

from thumble_receiver.artwork import IconLookup


class ArtworkTests(unittest.TestCase):
    def test_names_are_validated_cached_and_failures_are_optional(self):
        calls = []
        def request(url, **kwargs):
            calls.append(url)
            return dict(icon='SPELL_NATURE_LIGHTNING')
        lookup = IconLookup(request=request)
        lookup.begin()
        self.assertEqual(lookup('spell', 6603), 'ability_meleedamage')
        self.assertEqual(lookup('spell', 403), 'spell_nature_lightning')
        self.assertEqual(lookup('spell', 403), 'spell_nature_lightning')
        self.assertEqual(len(calls), 1)
        self.assertIsNone(lookup('lua', 1))
        self.assertIsNone(lookup('item', True))
        invalid = IconLookup(request=lambda *args, **kwargs: dict(icon='https://attacker.example/image'))
        invalid.begin()
        self.assertIsNone(invalid('spell', 1))

    def test_request_count_is_bounded(self):
        calls = []
        lookup = IconLookup(request=lambda url, **kwargs: calls.append(url) or {})
        lookup.begin()
        for identifier in range(1, 100):
            lookup('spell', identifier)
        self.assertEqual(len(calls), 6)
