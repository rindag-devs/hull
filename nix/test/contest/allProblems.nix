{ hull, ... }:

{
  name = "allProblems";

  problems = [
    ../problem/aPlusB
    ../problem/aPlusBGrader
    ../problem/numberGuessing
    ../problem/recitePi
    ../problem/newYearGreeting
  ];

  targets = {
    default = hull.contestTarget.common { };
  };
}
