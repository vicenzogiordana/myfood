import unittest

from optimizador import _solve


def payload(candidates, budget=10_000):
    return {
        "days": ["2026-09-07"],
        "slots": ["lunch"],
        "constraints": {
            "weekly_budget_cents": budget,
            "inventory_weight": 100,
            "macro_bounds": {
                key: {"min": 0, "max": 10_000}
                for key in ["protein_g", "carbs_g", "fat_g", "calories"]
            },
        },
        "candidates_by_slot": {"lunch": candidates},
    }


class OptimizerTests(unittest.TestCase):
    def test_inventory_is_a_soft_preference(self):
        result, error = _solve(payload([{"recipe_id": "only", "estimated_cost_cents": 200}]))
        self.assertIsNone(error)
        assert result is not None
        self.assertEqual(result["meals"][0]["recipe_id"], "only")

    def test_inventory_hit_wins_an_otherwise_equal_choice(self):
        result, error = _solve(payload([
            {"recipe_id": "low", "estimated_cost_cents": 500, "inventory_hit_count": 0},
            {"recipe_id": "high", "estimated_cost_cents": 500, "inventory_hit_count": 1},
        ]))
        self.assertIsNone(error)
        assert result is not None
        self.assertEqual(result["meals"][0]["recipe_id"], "high")

    def test_budget_infeasibility_identifies_a_hard_constraint(self):
        result, error = _solve(payload([{"recipe_id": "costly", "estimated_cost_cents": 200}], budget=100))
        self.assertIsNone(result)
        self.assertEqual(error, ("infeasible", ["budget_too_low"]))

    def test_equal_candidates_have_a_stable_selection(self):
        candidates = [
            {"recipe_id": "recipe-b", "estimated_cost_cents": 500},
            {"recipe_id": "recipe-a", "estimated_cost_cents": 500},
        ]

        first, first_error = _solve(payload(candidates))
        second, second_error = _solve(payload(list(reversed(candidates))))

        self.assertIsNone(first_error)
        self.assertIsNone(second_error)
        assert first is not None
        self.assertEqual(first, second)
        self.assertEqual(first["meals"][0]["recipe_id"], "recipe-a")


if __name__ == "__main__":
    unittest.main()
