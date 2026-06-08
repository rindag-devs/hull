{
  introduction = {
    title = "Introduction";
    href = "/";
    source = "index.typ";
    target = "index.typ";
  };

  sections = [
    {
      title = "Getting Started";
      pages = [
        {
          title = "Installation & Setup";
          href = "/getting-started/installation-and-setup/";
          source = "getting-started/installation-and-setup.typ";
          target = "getting-started/installation-and-setup.typ";
        }
        {
          title = "Basic Workflow";
          href = "/getting-started/basic-workflow/";
          source = "getting-started/basic-workflow.typ";
          target = "getting-started/basic-workflow.typ";
        }
        {
          title = "Understanding problem.nix";
          href = "/getting-started/understanding-problem-nix/";
          source = "getting-started/understanding-problem-nix.typ";
          target = "getting-started/understanding-problem-nix.typ";
        }
        {
          title = "Understanding contest.nix";
          href = "/getting-started/understanding-contest-nix/";
          source = "getting-started/understanding-contest-nix.typ";
          target = "getting-started/understanding-contest-nix.typ";
        }
        {
          title = "Best Practices & Conventions";
          href = "/getting-started/best-practices-and-conventions/";
          source = "getting-started/best-practices-and-conventions.typ";
          target = "getting-started/best-practices-and-conventions.typ";
        }
      ];
    }
    {
      title = "Advanced";
      pages = [
        {
          title = "Custom Judgers";
          href = "/advanced/custom-judgers/";
          source = "advanced/custom-judgers.typ";
          target = "advanced/custom-judgers.typ";
        }
        {
          title = "Problem and Contest Targets";
          href = "/advanced/problem-and-contest-targets/";
          source = "advanced/problem-and-contest-targets.typ";
          target = "advanced/problem-and-contest-targets.typ";
        }
        {
          title = "Document Generation with Typst";
          href = "/advanced/document-generation-with-typst/";
          source = "advanced/document-generation-with-typst.typ";
          target = "advanced/document-generation-with-typst.typ";
        }
      ];
    }
    {
      title = "Reference";
      pages = [
        {
          title = "Problem Options Reference";
          href = "/reference/problem-options/";
          target = "reference/problem-options.typ";
          generated = "problemModuleOptions";
        }
        {
          title = "Contest Options Reference";
          href = "/reference/contest-options/";
          target = "reference/contest-options.typ";
          generated = "contestModuleOptions";
        }
      ];
    }
  ];
}
