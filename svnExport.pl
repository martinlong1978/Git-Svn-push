#!/usr/bin/perl

use File::Path;
use File::Basename;

$SYNC_BASE="/home/martin/gittest";
$GIT_ROOT="$SYNC_BASE/GIT";
$SVN_ROOT="$SYNC_BASE/SVNtmp";
$COMMIT_MESG="$SYNC_BASE/SVNtmp/messages";
$SVN_BASE_URL="https://www.rozel.net/svn/martin";
$REMOTE="origin";
@BRANCH_ORDER=("origin/trunk", "origin/1.0", "origin/2.0");

sub branchfromparent
{
	my $project=$_[0];
	my $branch=$_[1];
	my $br_parent=$_[2];
	my $revision=$_[3];
	my $svn_from="$SVN_BASE_URL/$project/$br_parent/trunk";
	my $svn_to="$SVN_BASE_URL/$project/$branch/trunk";
	
	print "Branching $branch from $br_parent at rev $revision\n";
	
	my $svnrev=`cat $SVN_ROOT/revcache |grep $revision |cut -d " " -f 1`;
	
	#Create tracking tag in GIT
	system("git tag -f svnbranch/$branch $revision");
	
	#Branch and checkout working copy
	system("svn copy --parents  $svn_from@$svnrev $svn_to -m \"Branch for $branch\"");
	mkpath "$SVN_ROOT/$project/$1";
	chdir "$SVN_ROOT/$project";
	system("svn co $svn_to $branch");

}

sub createfirst
{
	my $project=$_[0];
	my $branch=$_[1];
	my $revision=$_[2];
	my $svn_url="$SVN_BASE_URL/$project/$branch/trunk"

	print "New project branch: $branch\n";
	
	#Create tracking tag in GIT
	system("git tag -f svnbranch/$branch $revision");
	
	#Create branch and checkout working copy
	system("svn mkdir --parents $svn_url -m \"First branch\""); 
	mkpath "$SVN_ROOT/$project/$branch" or die("Couldn't make svn temp store: $SVN_ROOT/$project/$branch";
	chdir "$SVN_ROOT/$project" or die("Couldn't jump to svn temp store: $SVN_ROOT/$project/$branch";
	system("svn co $svn_url $branch") or die("Couldn't check out branch: $branch of $project");
}

sub findparent
{
	$branch=$_[0];
	$project=$_[1];
	print "Looking for parent of: $branch\n";
	open(REVS, "git rev-list --first-parent remotes/$branch |") or die "Broken";
	@revisions=<REVS>;
	close(REVS);
	
	for $revision (@revisions)
	{
		$revision =~ s/\n//;
		print "Looking for parent in rev: $revision\n";
		$br_parent=`cat $SVN_ROOT/revcache |grep $revision | cut -d " " -f 2`;
		$br_parent=~ /s\n//;
		if($br_parent ne "")
		{
			&branch_from_parent($project, $branch, $br_parent, $revision);
			return;
		}
		$rev_last=$revision;
	}
	&createfirst($project, $branch, $rev_last);	
}

sub processproject
{
	my $project=$_[0];
	print "Processing project: $project\n";
	
	chdir "$GIT_ROOT/$project" or die "Can't change to project directory: $project";
	
	system("git fetch --all");
	
	open(REFS, "git for-each-ref --format=\"\%(refname:short)\" refs/remotes/$REMOTE |grep -v HEAD|");
	@allbranches=<REFS>;
	close(REFS);
	
	for $branch (@BRANCH_ORDER)
	{
		push(@branches, $branch);
	}
	
	for $branch (@allbranches)
	{
		$branch =~ s/\n//;
		if(!grep($branch eq $_, @BRANCH_ORDER))
		{
			push(@branches, $branch);
		}
	}

	print "Branches: @branches\n";
	
	for $branch (@branches)
	{
		&processbranch($project, $branch);
	}
	
}

sub processbranch
{
	my ($project, $branch) = ($_[0],$_[1]);
	print "Processing $branch of $project\n";

	chdir "$GIT_ROOT/$project" or die "Can't change to project directory: $project";
	
	$tag=`git tag -l svnbranch/$branch | wc -l`;
	$tag =~ s/\n//;
	if($tag < 1)
	{
		&findparent($branch);
	}
	
	# Continue here
	

}

sub doimport
{
	mkpath $COMMIT_MESG;
	
	for $project (glob "$GIT_ROOT/*")
	{
		&processproject(basename($project));
	}

}

&doimport;

