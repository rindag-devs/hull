{
  hull,
  ...
}:

{
  name = "aPlusBContest";

  displayName = {
    en = "A+B contest";
    zh = "A+B 比赛";
  };

  problems = [ ../problem/aPlusB ];

  targets = {
    cnoiParticipant = hull.contestTarget.cnoiParticipant {
      targetSystem = "x86_64-linux";
      archive = "zip";
      xzCompressionLevel = 0;
      zipCompressionLevel = 0;
      enableSelfEval = true;
      displayLanguages = [
        "en"
        "zh"
      ];
      statements.aPlusB = {
        en = ../problem/aPlusB/document/statement/en.typ;
        zh = ../problem/aPlusB/document/statement/zh.typ;
      };
    };
    cnoiParticipantAarch64 = hull.contestTarget.cnoiParticipant {
      targetSystem = "aarch64-linux";
      archive = "zip";
      xzCompressionLevel = 0;
      zipCompressionLevel = 0;
      enableSelfEval = true;
      displayLanguages = [
        "en"
        "zh"
      ];
      statements.aPlusB = {
        en = ../problem/aPlusB/document/statement/en.typ;
        zh = ../problem/aPlusB/document/statement/zh.typ;
      };
    };
  };
}
