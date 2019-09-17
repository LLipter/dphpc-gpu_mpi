#include "clang/Frontend/FrontendActions.h"
#include "clang/Tooling/CommonOptionsParser.h"
#include "clang/Frontend/CompilerInstance.h"
#include "clang/Tooling/Tooling.h"
#include "clang/ASTMatchers/ASTMatchers.h"
#include "clang/ASTMatchers/ASTMatchFinder.h"
#include "clang/Rewrite/Core/Rewriter.h"

#include "llvm/Support/CommandLine.h"

using namespace clang;
using namespace clang::ast_matchers;
using namespace clang::tooling;
using namespace llvm;


// Apply a custom category to all command-line options so that they are the
// only ones displayed.
static cl::OptionCategory MyToolCategory("my-tool options");

// CommonOptionsParser declares HelpMessage with a description of the common
// command-line options related to the compilation database and input files.
// It's nice to have this help message in all tools.
static cl::extrahelp CommonHelp(CommonOptionsParser::HelpMessage);

// A help message for this specific tool can be added afterwards.
static cl::extrahelp MoreHelp("\nMore help text...\n");

class FuncConverter : public MatchFinder::MatchCallback {
public :
    FuncConverter(Rewriter& rewriter) : mRewriter(rewriter) {

    }
    virtual void run(const MatchFinder::MatchResult &Result) {
        if (const FunctionDecl *func = Result.Nodes.getNodeAs<FunctionDecl>("func")) {
            if (func->isMain()) {
                llvm::errs() << "Detected main function\n";
                mRewriter.ReplaceText(func->getNameInfo().getSourceRange(), "__gpu_main");
                mRewriter.InsertTextAfterToken(func->getEndLoc(), "\n\n__global__ void __gpu_main_kernel(int argc, char* argv[]) { __gpu_main(argc, argv); }");
            }

            llvm::errs() << "Annotating function " << func->getName() << " with __device__\n";
            mRewriter.InsertTextBefore(func->getSourceRange().getBegin(), "__device__ ");
        }
    }
private:
    Rewriter& mRewriter;
};

class MyASTConsumer : public ASTConsumer {
public:
    MyASTConsumer(Rewriter &rewriter) : mFuncConverter(rewriter) {
        mMatcher.addMatcher(functionDecl().bind("func"), &mFuncConverter);
    }

    void HandleTranslationUnit(ASTContext &Context) override {
        // Run the matchers when we have the whole TU parsed.
        mMatcher.matchAST(Context);
    }

private:
    FuncConverter mFuncConverter;
    MatchFinder mMatcher;
};

class MyFrontendAction : public ASTFrontendAction {
public:
    void EndSourceFileAction() override {
        SourceManager &sm = mRewriter.getSourceMgr();

        StringRef fname = sm.getFileEntryForID(sm.getMainFileID())->getName();
        llvm::errs() << "** EndSourceFileAction for: " << fname << "\n";

        std::error_code error_code;
        llvm::raw_fd_ostream outFile((fname + ".cu").str(), error_code,
                                     llvm::sys::fs::OF_None);
        mRewriter.getEditBuffer(sm.getMainFileID()).write(outFile);
    }

    std::unique_ptr<ASTConsumer> CreateASTConsumer(
            CompilerInstance& ci, StringRef file) override
    {
        llvm::errs() << "** Creating AST consumer for: " << file << "\n";
        mRewriter.setSourceMgr(ci.getSourceManager(), ci.getLangOpts());
        return llvm::make_unique<MyASTConsumer>(mRewriter);
    }
private:
    Rewriter mRewriter;
};

int main(int argc, const char **argv) {
    CommonOptionsParser OptionsParser(argc, argv, MyToolCategory);
    ClangTool Tool(OptionsParser.getCompilations(),
                   OptionsParser.getSourcePathList());
    return Tool.run(newFrontendActionFactory<MyFrontendAction>().get());
}