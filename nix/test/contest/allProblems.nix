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
    lemonCustom = hull.contestTarget.lemonCustom {
      problemTarget = "lemonCustom";
    };
    cnoiParticipant =
      let
        displayLanguages = [
          "en"
          "zh"
        ];
      in
      hull.contestTarget.cnoiParticipant {
        inherit displayLanguages;
        targetSystem = "x86_64-linux";
        archive = "zip";
        statements = builtins.listToAttrs (
          map (p: {
            name = p.config.name;
            value = builtins.listToAttrs (
              map (l: {
                name = l;
                value = ./. + "/../problem/${p.config.name}/document/statement/${l}.typ";
              }) displayLanguages
            );
          }) config.problems
        );
        enableSelfEval = true;
      };
    cnoiParticipantAarch64 =
      let
        displayLanguages = [
          "en"
          "zh"
        ];
      in
      hull.contestTarget.cnoiParticipant {
        inherit displayLanguages;
        targetSystem = "aarch64-linux";
        archive = "zip";
        statements = builtins.listToAttrs (
          map (p: {
            name = p.config.name;
            value = builtins.listToAttrs (
              map (l: {
                name = l;
                value = ./. + "/../problem/${p.config.name}/document/statement/${l}.typ";
              }) displayLanguages
            );
          }) config.problems
        );
        enableSelfEval = true;
      };
    cnoiParticipantDarwin =
      let
        displayLanguages = [
          "en"
          "zh"
        ];
      in
      hull.contestTarget.cnoiParticipant {
        inherit displayLanguages;
        targetSystem = "x86_64-darwin";
        archive = "zip";
        statements = builtins.listToAttrs (
          map (p: {
            name = p.config.name;
            value = builtins.listToAttrs (
              map (l: {
                name = l;
                value = ./. + "/../problem/${p.config.name}/document/statement/${l}.typ";
              }) displayLanguages
            );
          }) config.problems
        );
        enableSelfEval = true;
      };
  };
}
