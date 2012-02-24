#!/bin/bash

if [ -z $SVN_REPO_URL ]
then
    echo "Please set SVN_REPO_URL" 1>&2
    exit 1
fi

   trunk_regex="git-svn-id: $SVN_REPO_URL/trunk@([0-9]*)"
branches_regex="git-svn-id: $SVN_REPO_URL/branches/(\S*)@([0-9]*)"

not_completed_refs=

git rev-list $(git for-each-ref --format='%(refname)' refs/remotes/) $not_completed_refs --reverse | while read sha
do
	git_svn_id=$(git log -1 --format=format:%B "$sha" | grep git-svn-id)
	if [[ $git_svn_id =~ $trunk_regex ]]
	then
		branch=master
		svn_revision=${BASH_REMATCH[1]}
	elif [[ $git_svn_id =~ $branches_regex ]]
	then
		branch=${BASH_REMATCH[1]}
		svn_revision=${BASH_REMATCH[2]}
	else
		echo "No match with $git_svn_id" 1>&2
		continue
	fi
	echo $svn_revision $branch $sha
done

exit 0
