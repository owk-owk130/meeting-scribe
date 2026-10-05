import unittest

from merge_transcript import label_speakers, render


def seg(start, end, label, text="x"):
    return [start, end, label, text]


class LabelSpeakersTest(unittest.TestCase):
    def test_segment_takes_speaker_with_largest_overlap(self):
        turns = [[0, 1000, "SPEAKER_00"], [1000, 5000, "SPEAKER_01"], [5000, 6000, "SPEAKER_00"]]
        labeled = label_speakers([seg(500, 4000, "相手"), seg(5000, 6000, "相手")], turns, "相手")
        self.assertEqual([s[2] for s in labeled], ["相手A", "相手B"])

    def test_segment_without_overlap_takes_nearest_speaker(self):
        turns = [[0, 1000, "SPEAKER_00"], [9000, 10000, "SPEAKER_01"]]
        labeled = label_speakers([seg(0, 1000, "相手"), seg(7500, 8000, "相手")], turns, "相手")
        self.assertEqual([s[2] for s in labeled], ["相手A", "相手B"])

    def test_letters_follow_order_of_first_appearance(self):
        turns = [[0, 1000, "SPEAKER_01"], [1000, 2000, "SPEAKER_00"]]
        labeled = label_speakers([seg(0, 1000, "話者"), seg(1000, 2000, "話者")], turns, "話者")
        self.assertEqual([s[2] for s in labeled], ["話者A", "話者B"])

    def test_single_speaker_keeps_plain_label(self):
        turns = [[0, 1000, "SPEAKER_00"], [2000, 3000, "SPEAKER_00"]]
        labeled = label_speakers([seg(0, 1000, "相手"), seg(2000, 3000, "相手")], turns, "相手")
        self.assertEqual([s[2] for s in labeled], ["相手", "相手"])

    def test_no_turns_keeps_plain_label(self):
        labeled = label_speakers([seg(0, 1000, "自分")], [], "話者")
        self.assertEqual([s[2] for s in labeled], ["自分"])


class RenderTest(unittest.TestCase):
    def test_mono_with_several_speakers_is_labeled(self):
        lines = render([seg(0, 1000, "話者A", "a"), seg(3000, 4000, "話者B", "b")], [], 0, "auto")
        self.assertEqual(lines, ["- [00:00] 🔵 **話者A**: a", "- [00:03] 🟠 **話者B**: b"])

    def test_mono_with_one_speaker_is_plain_text(self):
        lines = render([seg(0, 1000, "自分", "a"), seg(70000, 71000, "自分", "b")], [], 0, "auto")
        self.assertEqual(lines, ["a", "b"])

    def test_others_alone_is_still_labeled(self):
        lines = render([], [seg(0, 1000, "相手", "a")], 0, "auto")
        self.assertEqual(lines, ["- [00:00] 🔵 **相手**: a"])

    def test_same_speaker_keeps_same_color(self):
        mine = [seg(0, 1000, "自分", "a"), seg(10000, 11000, "自分", "c")]
        others = [seg(3000, 4000, "相手", "b")]
        lines = render(mine, others, 0, "auto")
        self.assertEqual(lines, ["- [00:00] 🔵 **自分**: a", "- [00:03] 🟠 **相手**: b", "- [00:10] 🔵 **自分**: c"])

    def test_colors_cycle_after_running_out(self):
        segments = [seg(i * 10000, i * 10000 + 1000, f"話者{i}", "x") for i in range(10)]
        lines = render(segments, [], 0, "auto")
        self.assertTrue(lines[9].startswith("- [01:30] 🔵 "))

    def test_live_lines_have_no_color(self):
        lines = render([seg(0, 1000, "自分", "a")], [seg(3000, 4000, "相手", "b")], 0, "always")
        self.assertEqual(lines, ["[00:00] 自分: a", "[00:03] 相手: b"])


if __name__ == "__main__":
    unittest.main()
