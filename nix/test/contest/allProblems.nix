{
  hull,
  config,
  ...
}:

{
  name = "allProblems";

  displayName = {
    en = "all problems";
    zh = "所有题目";
  };

  problems = [
    ../problem/aPlusB
    ../problem/aPlusBGrader
    ../problem/numberGuessing
    ../problem/recitePi
    ../problem/newYearGreeting
    ../problem/mst
  ];

  targets = {
    default = hull.contestTarget.common { };
    cnoiParticipant =
      let
        displayLanguages = [
          "en"
          "zh"
        ];
      in
      hull.contestTarget.cnoiParticipant {
        inherit displayLanguages;
        statements = builtins.listToAttrs (
          map (p: {
            name = p.config.name;
            value = builtins.listToAttrs (
              map (l: {
                name = l;
                value = ./. + "/../problem/${p.config.name}/document/statement/problem/${l}.typ";
              }) displayLanguages
            );
          }) config.problems
        );
      };
  };
}
