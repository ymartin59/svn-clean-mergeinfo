# svn-clean-mergeinfo.pl
# Automated test case

.PHONY: clean tests

DIST=dist
TESTWC=$(DIST)/wc-root
# Determine this makefile's path
THIS_FILE := $(lastword $(MAKEFILE_LIST))

clean:
	rm -rf $(DIST)

createdata: clean
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

createdatabis:
	echo "A++" >> $(TESTWC)/branches/Br1/first/A
	echo "B++" >> $(TESTWC)/branches/Br1/first/second/B
	echo "C++" >> $(TESTWC)/branches/Br1/first/second/third/C
	svn commit -m "Change A+B+C on branches/Br1" $(TESTWC)   # Revision 5
	(cd $(TESTWC); svn up)

domergeAinfirst:
	(cd $(TESTWC)/trunk/first; svn merge -c 4 ^/branches/Br1/first .)
	svn commit -m "Merge A on trunk in first" $(TESTWC)

domergeCinsecond:
	(cd $(TESTWC)/trunk/first/second; svn merge -c 3 ^/branches/Br1/first/second .)
	svn commit -m "Merge C on trunk in first/second" $(TESTWC)

domergeC:
	(cd $(TESTWC); svn up)
	(cd $(TESTWC)/trunk; svn merge -c 3 ^/branches/Br1 .)
	svn commit -m "Merge C on trunk" $(TESTWC)

domergeB:
	(cd $(TESTWC); svn up)
	(cd $(TESTWC)/trunk/first/second; svn merge -c 5 ^/branches/Br1/first/second/B B)
	svn commit -m "Merge B on trunk in first/second" $(TESTWC)

domergeBimmediates:
	(cd $(TESTWC); svn up)
	(cd $(TESTWC)/trunk/first/second; svn merge --depth=immediates -c 5 ^/branches/Br1/first/second .)
	svn commit -m "Merge B on trunk in first/second" $(TESTWC)

domergeBfiles:
	(cd $(TESTWC); svn up)
	(cd $(TESTWC)/trunk/first/second; svn merge --depth=files -c 5 ^/branches/Br1/first/second .)
	svn commit -m "Merge B on trunk in first/second" $(TESTWC)

domergeOK:
	(cd $(TESTWC)/trunk; svn merge -c 3,4 ^/branches/Br1 .)
	svn commit -m "Merge A+C on trunk" $(TESTWC)

doincorrectbranch:
	(cd $(TESTWC)/trunk; svn update; svn propset "svn:mergeinfo" "/branches/Br1/firstafter: 4" first)
	svn commit -m "Create mergeinfo on trunk/first" $(TESTWC)/trunk

dolocalcopy:
	(cd $(TESTWC)/branches/Br1; svn copy ^/trunk/first firstbis)
	svn commit -m "Branch /trunk/first as /branches/Br1/firstbis" $(TESTWC)/branches/Br1

domergelocalcopy:
	(cd $(TESTWC)/branches/Br1; svn update; svn merge ^/trunk/first firstbis)
	svn commit -m "Merge /trunk/first to /branches/Br1/firstbis" $(TESTWC)/branches/Br1

consolidate:
	(cd $(WCPATH); $(PWD)/svn-clean-mergeinfo.pl --debug $(CLEAN_OPTS))

checkbefore: CHECK=BEFORE
checkafter: CHECK=AFTER
checkbefore checkafter:
	@echo "\n====================================" $(CHECK)
	@(cd $(WCPATH); svn propget "svn:mergeinfo" --depth=infinity)
	@echo "====================================" $(CHECK)
	(cd $(WCPATH); $(PWD)/svn-clean-mergeinfo.pl --verbose --status)

operate: checkbefore consolidate checkafter

# Compare "svn:mergeinfo" present in working copy to expected result
validate:
	svn propget "svn:mergeinfo" --depth=infinity $(TESTPATH) > $(DIST)/propget-$(TESTNAME).log
	diff tests/propget-$(TESTNAME).log $(DIST)/propget-$(TESTNAME).log

testOK: WCPATH=$(TESTWC)/trunk
testOK: createdata domergeOK operate
	@$(MAKE) -f $(THIS_FILE) validate TESTNAME=$@ TESTPATH=$(WCPATH)

testK%: WCPATH=$(TESTWC)/trunk
testKO1: createdata domergeAinfirst domergeCinsecond operate
	@$(MAKE) -f $(THIS_FILE) validate TESTNAME=$@ TESTPATH=$(WCPATH)

testKO2: createdata domergeAinfirst domergeC operate
	@$(MAKE) -f $(THIS_FILE) validate TESTNAME=$@ TESTPATH=$(WCPATH)

testKO3: createdata createdatabis domergeB operate
	@$(MAKE) -f $(THIS_FILE) validate TESTNAME=$@ TESTPATH=$(WCPATH)

testKO4: createdata createdatabis domergeBimmediates operate
	@$(MAKE) -f $(THIS_FILE) validate TESTNAME=$@ TESTPATH=$(WCPATH)

testKO5: createdata createdatabis domergeBfiles operate
	@$(MAKE) -f $(THIS_FILE) validate TESTNAME=$@ TESTPATH=$(WCPATH)

testKO6: createdata domergeOK doincorrectbranch operate
	@$(MAKE) -f $(THIS_FILE) validate TESTNAME=$@ TESTPATH=$(WCPATH)

testOKnonrootbranch: WCPATH=$(TESTWC)/branches/Br1
testOKnonrootbranch: createdata dolocalcopy createdatabis domergelocalcopy operate
	@$(MAKE) -f $(THIS_FILE) validate TESTNAME=$@ TESTPATH=$(WCPATH)

testprune: WCPATH=$(TESTWC)/trunk
testprune: CLEAN_OPTS=--prunebranches
testprune: createdata domergeOK doincorrectbranch operate
	@$(MAKE) -f $(THIS_FILE) validate TESTNAME=$@ TESTPATH=$(WCPATH)
