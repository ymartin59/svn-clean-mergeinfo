# svn-clean-mergeinfo.pl
# Automated test case

DIST=dist
TESTWC=$(DIST)/wc-root

clean:
	rm -rf $(DIST)

testdata:
	mkdir $(DIST)
	svnadmin create $(DIST)/testrepo
	svn co file:///`pwd`/$(DIST)/testrepo $(TESTWC)
	mkdir --parents $(TESTWC)/trunk/first/second/third $(TESTWC)/branches
	echo "A" > $(TESTWC)/trunk/first/A
	echo "B" > $(TESTWC)/trunk/first/second/B
	echo "C" > $(TESTWC)/trunk/first/second/third/C
	(cd $(TESTWC); svn add *)
	(cd $(TESTWC); svn commit -m "Structure and initial data")
	echo "B+" >> $(TESTWC)/trunk/first/second/B
	(cd $(TESTWC); svn commit -m "Change B on trunk")
	(cd $(TESTWC); svn up)
	svn copy $(TESTWC)/trunk $(TESTWC)/branches/Br1
	echo "C+" >> $(TESTWC)/branches/Br1/first/second/third/C
	svn commit -m "Change C on branches/Br1" $(TESTWC)   # Revision 3
	echo "A+" >> $(TESTWC)/branches/Br1/first/A
	svn commit -m "Change A on branches/Br1" $(TESTWC)   # Revision 4
	(cd $(TESTWC); svn up)

testdatabis:
	echo "A++" >> $(TESTWC)/branches/Br1/first/A
	echo "B++" >> $(TESTWC)/branches/Br1/first/second/B
	echo "C++" >> $(TESTWC)/branches/Br1/first/second/third/C
	svn commit -m "Change A+B+C on branches/Br1" $(TESTWC)   # Revision 5
	(cd $(TESTWC); svn up)

testmergeAinfirst:
	(cd $(TESTWC)/trunk/first; svn merge -c 4 ^/branches/Br1/first .)
	svn commit -m "Merge A on trunk in first" $(TESTWC)

testmergeCinsecond:
	(cd $(TESTWC)/trunk/first/second; svn merge -c 3 ^/branches/Br1/first/second .)
	svn commit -m "Merge C on trunk in first/second" $(TESTWC)

testmergeC:
	(cd $(TESTWC); svn up)
	(cd $(TESTWC)/trunk; svn merge -c 3 ^/branches/Br1 .)
	svn commit -m "Merge C on trunk" $(TESTWC)

testmergeB:
	(cd $(TESTWC); svn up)
	(cd $(TESTWC)/trunk/first/second; svn merge -c 5 ^/branches/Br1/first/second/B B)
	svn commit -m "Merge B on trunk in first/second" $(TESTWC)

testmergeBimmediates:
	(cd $(TESTWC); svn up)
	(cd $(TESTWC)/trunk/first/second; svn merge --depth=immediates -c 5 ^/branches/Br1/first/second .)
	svn commit -m "Merge B on trunk in first/second" $(TESTWC)

testmergeBfiles:
	(cd $(TESTWC); svn up)
	(cd $(TESTWC)/trunk/first/second; svn merge --depth=files -c 5 ^/branches/Br1/first/second .)
	svn commit -m "Merge B on trunk in first/second" $(TESTWC)

testmergeOK:
	(cd $(TESTWC)/trunk; svn merge -c 3,4 ^/branches/Br1 .)
	svn commit -m "Merge A+C on trunk" $(TESTWC)

testincorrectbranch:
	(cd $(TESTWC)/trunk; svn update; svn propset "svn:mergeinfo" "/branches/Br1/firstafter: 4" first)
	svn commit -m "Create mergeinfo on trunk/first" $(TESTWC)/trunk

testlocalcopy:
	(cd $(TESTWC)/branches/Br1; svn copy ^/trunk/first firstbis)
	svn commit -m "Branch /trunk/first as /branches/Br1/firstbis" $(TESTWC)/branches/Br1

testmergelocalcopy:
	(cd $(TESTWC)/branches/Br1; svn update; svn merge ^/trunk/first firstbis)
	svn commit -m "Merge /trunk/first to /branches/Br1/firstbis" $(TESTWC)/branches/Br1
	(cd $(TESTWC)/branches/Br1; $(PWD)/svn-clean-mergeinfo.pl --debug)
	(cd $(TESTWC)/branches/Br1; $(PWD)/svn-clean-mergeinfo.pl --verbose --status)

consolidate:
	(cd $(TESTWC)/trunk; $(PWD)/svn-clean-mergeinfo.pl --debug)

checkbefore: target=before

checkafter: target=after

checkbefore checkafter:
	svn propget svn:mergeinfo --depth=infinity $(TESTWC)/trunk
	(cd $(TESTWC)/trunk; $(PWD)/svn-clean-mergeinfo.pl --verbose --status)

operate: checkbefore consolidate checkafter

testOK: testdata testmergeOK checkbefore

testKO1: testdata testmergeAinfirst testmergeCinsecond operate

testKO2: testdata testmergeAinfirst testmergeC operate

testKO3: testdata testdatabis testmergeB operate

testKO4: testdata testdatabis testmergeBimmediates operate

testKO5: testdata testdatabis testmergeBfiles operate

testKO6: testdata testmergeOK testincorrectbranch operate

testOKnonrootbranch: testdata testlocalcopy testdatabis testmergelocalcopy