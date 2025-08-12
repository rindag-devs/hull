{ pkgs }:

{
  # A placeholder for the batch judger.
  # In a real implementation, this would configure how solutions are run and checked.
  # For the MVP, it simply holds a reference to the checker derivation.
  batchJudger =
    { ... }:
    {
      _type = "hullJudger";

      __functor =
        self:
        { checker }:
        {
          inherit checker;
        };
    };
}
