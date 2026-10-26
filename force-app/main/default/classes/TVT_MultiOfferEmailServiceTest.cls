/**
 * TVT_MultiOfferEmailServiceTest.cls — Test coverage for TVT_MultiOfferEmailService.
 *
 * The HTML-manipulation helpers (replaceApprovedAmount / insertOfferContent / buildPositionsBlock)
 * are exercised directly with hand-built strings — no Opportunity or EmailTemplate needed for
 * those. Full send() tests use testTemplateMap to supply a test EmailTemplate without
 * depending on environment-specific template IDs. The production implementation resolves
 * White Label-specific templates and optional CC addresses from
 * Multi_Offer_Email_Template_Mapping__mdt; an unmatched or blank-template mapping falls back
 * to the Approval_Multi_Offer DeveloperName. Tests still depend on the org's deployed
 * Offer_Email_Address_Config__mdt.Default and Offer_Program_Config__mdt records.
 *
 * Test Isolation — Callout Strategy
 * ──────────────────────────────────
 * A Dragin_Engine trigger reaches a real outbound callout (Lendios/DND lookup) whenever an
 * Opportunity's StageName actually TRANSITIONS to 'Approval Given' — plain HttpCalloutMock
 * re-registration and startTest/stopTest ordering tricks alone weren't enough to stop it,
 * because those only cover callouts made directly by our own Apex, not ones a package trigger's
 * async flow reaches. The fix that works: createApprovalGivenOpportunity() inserts the test
 * Opportunity already AT StageName='Approval Given', so send()'s own update sets that same
 * value again — a no-op field change, not a Stage transition — and the trigger's entry
 * criteria never re-fires. Test.setMock() is still registered as a secondary safety net for any
 * other callout in the code path.
 *
 * @author Seda Ertugrul
 * @date 2026-07-22
 * @version 1.0
 */
@isTest
private class TVT_MultiOfferEmailServiceTest {

    /**
     * Updating the Opportunity after a send (StageName -> 'Approval Given', etc.) fires
     * unrelated managed-package automation that makes a real HTTP callout — not something this
     * test owns or can bypass directly. Test.setMock intercepts ANY callout made during the
     * test, regardless of which class makes it, so this neutralizes it without touching that
     * automation's code.
     */
    private class NoOpHttpMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{}');
            return res;
        }
    }

    private static void clearMocks() {
        TVT_MultiOfferEmailService.testTemplateMap = null;
        TVT_MultiOfferEmailService.skipSendEmailInTest = false;
    }

    private static Opportunity createTestOpportunity(String isoEmail) {
        Opportunity opp = new Opportunity(
            Name = 'Multi Offer Email Test Opp',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Dragin_Engine__ISO_Email__c = isoEmail,
            Dragin_Engine__Advance_Amount__c = 50000
        );
        Test.setMock(HttpCalloutMock.class, new NoOpHttpMock());
        insert opp;
        return opp;
    }

    /**
     * Opportunity created already AT StageName='Approval Given' — send() sets StageName to
     * that same value again, so it's a no-op field change rather than an actual Stage
     * transition. If the Dragin_Engine automation that reaches the Lendios/DND callout is keyed
     * on "StageName changes to Approval Given" (a real Stage transition), starting here already
     * avoids re-triggering it during send()'s own update.
     */
    private static Opportunity createApprovalGivenOpportunity(String isoEmail) {
        Opportunity opp = new Opportunity(
            Name = 'Multi Offer Email Test Opp',
            StageName = 'Approval Given',
            CloseDate = Date.today().addDays(30),
            Dragin_Engine__ISO_Email__c = isoEmail,
            Dragin_Engine__Advance_Amount__c = 50000
        );
        insert opp;
        return opp;
    }

    // ────────────────────────────────────────────────────────────────────────
    // replaceApprovedAmount
    // ────────────────────────────────────────────────────────────────────────

    @isTest
    static void testReplaceApprovedAmount_replacesStaleValue() {
        String html = '<div class="amount-hero"><span class="label">Approved Amount</span>'
            + '<span class="value">$0.00</span></div>';
        Decimal advanceAmount = 65000;

        Test.startTest();
        String result = TVT_MultiOfferEmailService.replaceApprovedAmount(html, advanceAmount);
        Test.stopTest();

        // Built the same way as replaceApprovedAmount itself, rather than a hardcoded literal —
        // Decimal.format() renders grouping/decimal separators per the org's locale, so a
        // hardcoded "$65,000.00" fails in any org not using an en_US-style locale.
        String expectedValue = '$' + advanceAmount.setScale(2).format();
        System.assert(result.contains(expectedValue), 'Approved Amount value should be replaced with the new advance amount');
        System.assert(!result.contains('>$0.00<'), 'Stale rendered value should not remain');
    }

    @isTest
    static void testReplaceApprovedAmount_noAmountHeroMarker_returnsUnchanged() {
        String html = '<div class="body">no amount hero here</div>';

        Test.startTest();
        String result = TVT_MultiOfferEmailService.replaceApprovedAmount(html, 65000);
        Test.stopTest();

        System.assertEquals(html, result, 'Html without an amount-hero div should be unchanged');
    }

    @isTest
    static void testReplaceApprovedAmount_nullAdvanceAmount_returnsUnchanged() {
        String html = '<div class="amount-hero"><span class="value">$0.00</span></div>';

        Test.startTest();
        String result = TVT_MultiOfferEmailService.replaceApprovedAmount(html, null);
        Test.stopTest();

        System.assertEquals(html, result, 'Html should be unchanged when advanceAmount is null');
    }

    // ────────────────────────────────────────────────────────────────────────
    // insertOfferContent
    // ────────────────────────────────────────────────────────────────────────

    @isTest
    static void testInsertOfferContent_insertsRightAfterMarker() {
        String html = 'before<!-- OFFER_CONTENT -->after';

        Test.startTest();
        String result = TVT_MultiOfferEmailService.insertOfferContent(html, 'NEW OFFER CONTENT');
        Test.stopTest();

        System.assert(result.contains('NEW OFFER CONTENT'), 'New content should be inserted');
        System.assert(
            result.indexOf('NEW OFFER CONTENT') > result.indexOf('<!-- OFFER_CONTENT -->'),
            'Content should be inserted right after the marker, not before it'
        );
    }

    @isTest
    static void testInsertOfferContent_noMarker_returnsUnchanged() {
        String html = '<div>no marker here</div>';

        Test.startTest();
        String result = TVT_MultiOfferEmailService.insertOfferContent(html, 'NEW');
        Test.stopTest();

        System.assertEquals(html, result, 'Html should be returned unchanged when the OFFER_CONTENT marker is missing');
    }

    // ────────────────────────────────────────────────────────────────────────
    // buildPositionsBlock
    // ────────────────────────────────────────────────────────────────────────

    @isTest
    static void testBuildPositionsBlock_wrapsPositionsRowsWithPayingOffHeading() {
        Test.startTest();
        String result = TVT_MultiOfferEmailService.buildPositionsBlock('<tr><td>Capital Co</td></tr>');
        Test.stopTest();

        System.assert(result.contains('Paying Off'), 'Positions block should be labeled "Paying Off"');
        System.assert(result.contains('<tr><td>Capital Co</td></tr>'), 'Positions rows should be included in the block');
    }

    @isTest
    static void testBuildPositionsBlock_blankPositionsRows_returnsEmptyString() {
        Test.startTest();
        String result = TVT_MultiOfferEmailService.buildPositionsBlock('');
        Test.stopTest();

        System.assertEquals('', result, 'No positions block should be built when there is nothing to show');
    }

    // ────────────────────────────────────────────────────────────────────────
    // send
    // ────────────────────────────────────────────────────────────────────────

    @isTest
    static void testSend_noIsoEmail_throwsEmailServiceException() {
        Opportunity opp = createTestOpportunity(null);

        List<TVT_MultiOfferEmailService.ProgramSelection> selections = new List<TVT_MultiOfferEmailService.ProgramSelection>();
        TVT_MultiOfferEmailService.ProgramSelection flex = new TVT_MultiOfferEmailService.ProgramSelection();
        flex.programLabel = 'Flex Program';
        flex.rows = new List<String>{ '1.30 buy rate | 32 weekly remits | 8 months' };
        selections.add(flex);

        Boolean threw = false;
        Test.startTest();
        try {
            TVT_MultiOfferEmailService.send(opp.Id, selections, 50000);
        } catch (TVT_MultiOfferEmailService.EmailServiceException ex) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'Should throw when the Opportunity has no ISO email');
    }

    @isTest
    static void testSend_success_updatesOpportunityFields() {
        EmailTemplate tmpl = TestDataFactory.createEmailTemplate('Multi_Offer_Email_Service_Test_Template', true);
        TVT_MultiOfferEmailService.testTemplateMap = new Map<String, Id>{ '' => tmpl.Id };
        // Note: skipSendEmailInTest is intentionally left false here — it returns before
        // updateOpportunityAfterSend() runs, which would skip the very fields this test checks.
        // Test execution never actually delivers the email regardless of this flag.

        TVT_MultiOfferEmailService.ProgramSelection flex = new TVT_MultiOfferEmailService.ProgramSelection();
        flex.programLabel = 'Flex Program';
        flex.rows = new List<String>{ '1.30 buy rate | 32 weekly remits | 8 months' };

        TVT_MultiOfferEmailService.ProgramSelection silver = new TVT_MultiOfferEmailService.ProgramSelection();
        silver.programLabel = 'BC Silver';
        silver.rows = new List<String>{ '1.32 buy rate | 28 weekly remits | 7 months' };

        List<TVT_MultiOfferEmailService.ProgramSelection> selections =
            new List<TVT_MultiOfferEmailService.ProgramSelection>{ flex, silver };

        Test.startTest();
        Opportunity opp = createApprovalGivenOpportunity('iso@example.com');
        Test.setMock(HttpCalloutMock.class, new NoOpHttpMock());
        TVT_MultiOfferEmailService.send(opp.Id, selections, 65000);
        Test.stopTest();

        Opportunity updated = [
            SELECT Flex_Offer_Rows__c, BC_Silver_Offer_Rows__c, Prime_Offer_Rows__c,
                   StageName, Dragin_Engine__Advance_Amount__c, Dragin_Engine__Offer_Sent_DateTime__c
            FROM Opportunity
            WHERE Id = :opp.Id
        ];
        System.assertEquals(
            '1.30 buy rate | 32 weekly remits | 8 months',
            updated.Flex_Offer_Rows__c,
            'Selected Flex row should be persisted'
        );
        System.assertEquals(
            '1.32 buy rate | 28 weekly remits | 7 months',
            updated.BC_Silver_Offer_Rows__c,
            'Selected BC Silver row should be persisted'
        );
        System.assertEquals(null, updated.Prime_Offer_Rows__c, 'Programs not selected should be cleared');
        System.assertEquals('Approval Given', updated.StageName);
        System.assertEquals(65000, updated.Dragin_Engine__Advance_Amount__c);
        System.assertNotEquals(null, updated.Dragin_Engine__Offer_Sent_DateTime__c);

        clearMocks();
    }

    @isTest
    static void testSend_withSelectedPositions_savesSnapshotAndDoesNotThrow() {
        EmailTemplate tmpl = TestDataFactory.createEmailTemplate('Multi_Offer_Email_Service_Test_Template_Positions', true);
        TVT_MultiOfferEmailService.testTemplateMap = new Map<String, Id>{ '' => tmpl.Id };

        TVT_MultiOfferEmailService.ProgramSelection flex = new TVT_MultiOfferEmailService.ProgramSelection();
        flex.programLabel = 'Flex Program';
        flex.rows = new List<String>{ '1.30 buy rate | 32 weekly remits | 8 months' };

        TVT_MultiOfferEmailService.PositionSelection position1 = new TVT_MultiOfferEmailService.PositionSelection();
        position1.position = 1;
        position1.name = 'Capital Co';
        position1.buyoffAmount = 1800;

        Test.startTest();
        Opportunity opp = createApprovalGivenOpportunity('iso@example.com');
        Test.setMock(HttpCalloutMock.class, new NoOpHttpMock());
        TVT_MultiOfferEmailService.send(
            opp.Id,
            new List<TVT_MultiOfferEmailService.ProgramSelection>{ flex },
            65000,
            new List<TVT_MultiOfferEmailService.PositionSelection>{ position1 }
        );
        Test.stopTest();

        Opportunity updated = [SELECT Multi_Offer_Send_Snapshot__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertNotEquals(null, updated.Multi_Offer_Send_Snapshot__c, 'Snapshot should be written when a position is selected');

        Map<String, Object> snapshot = (Map<String, Object>) JSON.deserializeUntyped(updated.Multi_Offer_Send_Snapshot__c);
        List<Object> selectedPositions = (List<Object>) snapshot.get('selectedPositions');
        System.assertEquals(1, selectedPositions.size());
        Map<String, Object> savedPosition = (Map<String, Object>) selectedPositions[0];
        System.assertEquals(1, (Integer) savedPosition.get('position'));
        System.assertEquals('Capital Co', (String) savedPosition.get('name'));
        System.assertEquals(1800, (Decimal) savedPosition.get('buyoffAmount'));

        clearMocks();
    }

    @isTest
    static void testSend_withTotalBuyoffAmount_writesPayoffField() {
        EmailTemplate tmpl = TestDataFactory.createEmailTemplate('Multi_Offer_Email_Service_Test_Template_Buyoff', true);
        TVT_MultiOfferEmailService.testTemplateMap = new Map<String, Id>{ '' => tmpl.Id };

        TVT_MultiOfferEmailService.ProgramSelection flex = new TVT_MultiOfferEmailService.ProgramSelection();
        flex.programLabel = 'Flex Program';
        flex.rows = new List<String>{ '1.30 buy rate | 32 weekly remits | 8 months' };

        Test.startTest();
        Opportunity opp = createApprovalGivenOpportunity('iso@example.com');
        Test.setMock(HttpCalloutMock.class, new NoOpHttpMock());
        TVT_MultiOfferEmailService.send(
            opp.Id,
            new List<TVT_MultiOfferEmailService.ProgramSelection>{ flex },
            65000,
            null,
            7500
        );
        Test.stopTest();

        Opportunity updated = [SELECT Dragin_Engine__Payoff_or_Buy_Off__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(7500, updated.Dragin_Engine__Payoff_or_Buy_Off__c, 'Total buyoff amount should be written on send');

        clearMocks();
    }

    @isTest
    static void testSend_emptySelectionRows_areSkipped() {
        EmailTemplate tmpl = TestDataFactory.createEmailTemplate('Multi_Offer_Email_Service_Test_Template_2', true);
        TVT_MultiOfferEmailService.testTemplateMap = new Map<String, Id>{ '' => tmpl.Id };
        // skipSendEmailInTest left false — see note in testSend_success_updatesOpportunityFields.

        TVT_MultiOfferEmailService.ProgramSelection empty = new TVT_MultiOfferEmailService.ProgramSelection();
        empty.programLabel = 'Prime Monthly';
        empty.rows = new List<String>();

        Test.startTest();
        Opportunity opp = createApprovalGivenOpportunity('iso@example.com');
        Test.setMock(HttpCalloutMock.class, new NoOpHttpMock());
        TVT_MultiOfferEmailService.send(opp.Id, new List<TVT_MultiOfferEmailService.ProgramSelection>{ empty }, 10000);
        Test.stopTest();

        Opportunity updated = [SELECT Prime_Offer_Rows__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(null, updated.Prime_Offer_Rows__c, 'A program with no rows selected should be cleared, not error');

        clearMocks();
    }

    /**
     * testSend_success_updatesOpportunityFields only ever selects 'Flex Program'/'BC Silver',
     * so updateOpportunityAfterSend's else-if branches for the other 5 programs (Prime Monthly,
     * Prime Weekly, AB Monthly, AB Prime, BC Power) never ran. Selecting all 7 here in one send()
     * exercises every branch. Also seeds Dragin_Engine__CC_Address__c (comma-separated, with
     * whitespace to hit the trim/isNotBlank checks) and Dragin_Engine__ISO_Rep_Email__c, so
     * buildCcList's branches run too — nothing outside send() can inspect the CC list it builds
     * (there's no test seam for the constructed SingleEmailMessage), so this only asserts the
     * Opportunity's own fields; the CC-list lines are covered as a side effect of running send().
     */
    @isTest
    static void testSend_allPrograms_updatesEveryOfferRowsField() {
        EmailTemplate tmpl = TestDataFactory.createEmailTemplate('Multi_Offer_Email_Service_Test_Template_3', true);
        TVT_MultiOfferEmailService.testTemplateMap = new Map<String, Id>{ '' => tmpl.Id };

        List<TVT_MultiOfferEmailService.ProgramSelection> selections = new List<TVT_MultiOfferEmailService.ProgramSelection>();
        Map<String, String> rowByProgram = new Map<String, String>{
            'Flex Program' => '1.30 buy rate | 32 weekly remits | 8 months',
            'Prime Monthly' => '1.20 buy rate | 7 months | 7 total remits',
            'Prime Weekly' => '1.20 buy rate | 28 weekly remits | 7 months',
            'AB Monthly' => '1.30 buy rate | 8 months | 8 total remits',
            'AB Prime' => '1.30 buy rate | 44 weekly remits | 11 months',
            'BC Power' => '1.38 buy rate | 32 weekly remits | 8 months',
            'BC Silver' => '1.32 buy rate | 28 weekly remits | 7 months'
        };
        for (String programLabel : rowByProgram.keySet()) {
            TVT_MultiOfferEmailService.ProgramSelection selection = new TVT_MultiOfferEmailService.ProgramSelection();
            selection.programLabel = programLabel;
            selection.rows = new List<String>{ rowByProgram.get(programLabel) };
            selections.add(selection);
        }

        Test.startTest();
        Opportunity opp = new Opportunity(
            Name = 'Multi Offer Email Test Opp - All Programs',
            StageName = 'Approval Given',
            CloseDate = Date.today().addDays(30),
            Dragin_Engine__ISO_Email__c = 'iso@example.com',
            Dragin_Engine__Advance_Amount__c = 50000,
            Dragin_Engine__CC_Address__c = ' cc1@example.com , cc2@example.com ',
            Dragin_Engine__ISO_Rep_Email__c = 'rep@example.com'
        );
        insert opp;
        Test.setMock(HttpCalloutMock.class, new NoOpHttpMock());
        TVT_MultiOfferEmailService.send(opp.Id, selections, 65000);
        Test.stopTest();

        Opportunity updated = [
            SELECT Flex_Offer_Rows__c, Prime_Offer_Rows__c, Prime_Weekly_Offer_Rows__c,
                   AB_Monthly_Offer_Rows__c, AB_Prime_Offer_Rows__c, BC_Power_Offer_Rows__c,
                   BC_Silver_Offer_Rows__c
            FROM Opportunity
            WHERE Id = :opp.Id
        ];
        System.assertEquals(rowByProgram.get('Flex Program'), updated.Flex_Offer_Rows__c);
        System.assertEquals(rowByProgram.get('Prime Monthly'), updated.Prime_Offer_Rows__c);
        System.assertEquals(rowByProgram.get('Prime Weekly'), updated.Prime_Weekly_Offer_Rows__c);
        System.assertEquals(rowByProgram.get('AB Monthly'), updated.AB_Monthly_Offer_Rows__c);
        System.assertEquals(rowByProgram.get('AB Prime'), updated.AB_Prime_Offer_Rows__c);
        System.assertEquals(rowByProgram.get('BC Power'), updated.BC_Power_Offer_Rows__c);
        System.assertEquals(rowByProgram.get('BC Silver'), updated.BC_Silver_Offer_Rows__c);

        clearMocks();
    }

    // ────────────────────────────────────────────────────────────────────────
    // buildOfferTableHtml — cosmetic displayLabel override
    // ────────────────────────────────────────────────────────────────────────

    @isTest
    static void testBuildOfferTableHtml_usesDisplayLabelWhenSet() {
        Opportunity opp = new Opportunity(Name = 'Display Label Test Opp');

        TVT_MultiOfferEmailService.ProgramSelection flex = new TVT_MultiOfferEmailService.ProgramSelection();
        flex.programLabel = 'Flex Program';
        flex.displayLabel = 'Custom Flex Name';
        flex.rows = new List<String>{ '1.30 buy rate | 32 weekly remits | 8 months' };

        Test.startTest();
        String html = TVT_MultiOfferEmailService.buildOfferTableHtml(
            new List<TVT_MultiOfferEmailService.ProgramSelection>{ flex },
            opp
        );
        Test.stopTest();

        System.assert(html.contains('Custom Flex Name'), 'Header should use the display label override');
        System.assert(
            !html.contains('>Flex Program Options<'),
            'The real program label should not appear as the header once overridden'
        );
    }

    @isTest
    static void testBuildOfferTableHtml_fallsBackToProgramLabelWhenNoDisplayLabel() {
        Opportunity opp = new Opportunity(Name = 'Display Label Test Opp 2');

        TVT_MultiOfferEmailService.ProgramSelection flex = new TVT_MultiOfferEmailService.ProgramSelection();
        flex.programLabel = 'Flex Program';
        flex.rows = new List<String>{ '1.30 buy rate | 32 weekly remits | 8 months' };

        Test.startTest();
        String html = TVT_MultiOfferEmailService.buildOfferTableHtml(
            new List<TVT_MultiOfferEmailService.ProgramSelection>{ flex },
            opp
        );
        Test.stopTest();

        System.assert(
            html.contains('>Flex Program Options<'),
            'Should fall back to the real program label when no display label override is set'
        );
    }

    // ────────────────────────────────────────────────────────────────────────
    // buildOfferTableHtml — per-deal Origination Fee/Max Upsell override
    // (Multi_Offer_Send_Snapshot__c "programOverrides", see TVT_MultiOfferController.saveProgramOverride)
    // ────────────────────────────────────────────────────────────────────────

    @isTest
    static void testBuildOfferTableHtml_programOverrideWinsOverCmdtDefault() {
        Opportunity opp = new Opportunity(Name = 'Program Override Test Opp');
        opp.Multi_Offer_Send_Snapshot__c = '{"programOverrides":{"Flex Program":{"maxUpsellPercent":12,"originationFeePercent":7}}}';

        TVT_MultiOfferEmailService.ProgramSelection flex = new TVT_MultiOfferEmailService.ProgramSelection();
        flex.programLabel = 'Flex Program';
        flex.rows = new List<String>{ '1.30 buy rate | 32 weekly remits | 8 months' };

        Test.startTest();
        String html = TVT_MultiOfferEmailService.buildOfferTableHtml(
            new List<TVT_MultiOfferEmailService.ProgramSelection>{ flex },
            opp
        );
        Test.stopTest();

        System.assert(html.contains('12%'), 'Program Details should show the overridden Max Upsell, not Offer_Program_Config__mdt\'s default');
        System.assert(html.contains('7%'), 'Program Details should show the overridden Origination Fee, not Offer_Program_Config__mdt\'s default');
    }

    @isTest
    static void testBuildOfferTableHtml_noOverride_fallsBackToCmdtDefault() {
        Opportunity opp = new Opportunity(Name = 'No Override Test Opp');

        TVT_MultiOfferEmailService.ProgramSelection flex = new TVT_MultiOfferEmailService.ProgramSelection();
        flex.programLabel = 'Flex Program';
        flex.rows = new List<String>{ '1.30 buy rate | 32 weekly remits | 8 months' };

        Test.startTest();
        String html = TVT_MultiOfferEmailService.buildOfferTableHtml(
            new List<TVT_MultiOfferEmailService.ProgramSelection>{ flex },
            opp
        );
        Test.stopTest();

        // No assertion on the actual CMDT value (real, deployed metadata, not test data — see
        // class header) — just that this doesn't throw and still renders a Program Details box.
        System.assert(html.contains('Program Details'), 'Should still render Program Details using the CMDT default when no override is saved');
    }

    // ────────────────────────────────────────────────────────────────────────
    // resolveTemplateId — real EmailTemplate query (DeveloperName = 'Approval_Multi_Offer'),
    // not the testTemplateMap seam. skipSendEmailInTest short-circuits send() right after
    // template/OWA resolution and html building, before Messaging.sendEmail and the
    // Opportunity update — so this doesn't need the callout-avoidance Stage tricks above.
    // ────────────────────────────────────────────────────────────────────────

    /**
     * Verifies the White Label records expected by the Multi Offer email feature.
     * EmailTemplate IDs differ by org, so test only that IDs are present and well-formed;
     * do not hardcode Sandbox IDs into a test that will also run in Production.
     */
    @isTest
    static void testWhiteLabelMappings_haveTemplateIds() {
        Map<String, Multi_Offer_Email_Template_Mapping__mdt> mappings =
            Multi_Offer_Email_Template_Mapping__mdt.getAll();

        for (String developerName : new List<String>{
            'Amajo_Corp',
            'C6_CAPITAL_SOOF',
            'Worldwide_Capital_UT',
            'TVT'
        }) {
            System.assert(mappings.containsKey(developerName),
                'Missing Multi Offer template mapping: ' + developerName);

            Multi_Offer_Email_Template_Mapping__mdt mapping = mappings.get(developerName);
            System.assert(String.isNotBlank(mapping.Approval_Template_ID__c),
                'Missing template ID for ' + developerName);

            String templateId = mapping.Approval_Template_ID__c.trim();
            System.assert(
                Pattern.compile('(?i)^00X[a-z0-9]{12}([a-z0-9]{3})?$')
                    .matcher(templateId).matches(),
                'Template ID must be a 15- or 18-character EmailTemplate ID: ' + developerName
            );
        }
    }

    /**
     * Regression check for Amajo Corp, which previously had an empty CC_Email__c.
     * Test execution does not deliver emails, so actual mailbox delivery must be
     * verified separately with a Sandbox send.
     */
    @isTest
    static void testAmajoMapping_hasCcEmail() {
        Multi_Offer_Email_Template_Mapping__mdt mapping =
            Multi_Offer_Email_Template_Mapping__mdt.getInstance('Amajo_Corp');

        System.assertNotEquals(null, mapping, 'Amajo Corp mapping must exist');
        System.assert(String.isNotBlank(mapping.CC_Email__c),
            'Amajo Corp must have a configured White Label CC email');
    }

    /**
     * Exercises send() for a mapped White Label, including its CC-building path,
     * while using a test EmailTemplate rather than an org-specific template ID.
     * Since constructed email recipients are not exposed by the service, this
     * verifies execution and the resulting Opportunity update, not email delivery.
     */
    @isTest
    static void testSend_amajoWhiteLabel_usesMappedCcPath() {
        EmailTemplate tmpl = TestDataFactory.createEmailTemplate(
            'Multi_Offer_Email_Service_Test_Amajo', true
        );
        TVT_MultiOfferEmailService.testTemplateMap =
            new Map<String, Id>{ 'Amajo Corp' => tmpl.Id };

        TVT_MultiOfferEmailService.ProgramSelection flex =
            new TVT_MultiOfferEmailService.ProgramSelection();
        flex.programLabel = 'Flex Program';
        flex.rows = new List<String>{ '1.30 buy rate | 32 weekly remits | 8 months' };

        Test.startTest();
        Opportunity opp = createApprovalGivenOpportunity('iso@example.com');
        opp.Dragin_Engine__White_Labels__c = 'Amajo Corp';
        opp.Dragin_Engine__CC_Address__c = ' cc1@example.com, cc2@example.com ';
        opp.Dragin_Engine__ISO_Rep_Email__c = 'rep@example.com';
        update opp;

        Test.setMock(HttpCalloutMock.class, new NoOpHttpMock());
        TVT_MultiOfferEmailService.send(
            opp.Id,
            new List<TVT_MultiOfferEmailService.ProgramSelection>{ flex },
            65000
        );
        Test.stopTest();

        Opportunity updated = [
            SELECT StageName, Flex_Offer_Rows__c
            FROM Opportunity
            WHERE Id = :opp.Id
        ];
        System.assertEquals('Approval Given', updated.StageName);
        System.assertEquals(flex.rows[0], updated.Flex_Offer_Rows__c);

        clearMocks();
    }

    /**
     * Confirms that the testTemplateMap override works for a blank White Label.
     * This isolates send() from org-specific EmailTemplate IDs.
     */
    @isTest
    static void testSend_blankWhiteLabel_usesTestTemplate() {
        EmailTemplate tmpl = TestDataFactory.createEmailTemplate(
            'Multi_Offer_Email_Service_Test_Unmapped', true
        );
        TVT_MultiOfferEmailService.testTemplateMap =
            new Map<String, Id>{ '' => tmpl.Id };

        TVT_MultiOfferEmailService.ProgramSelection flex =
            new TVT_MultiOfferEmailService.ProgramSelection();
        flex.programLabel = 'Flex Program';
        flex.rows = new List<String>{ '1.30 buy rate | 32 weekly remits | 8 months' };

        Test.startTest();
        Opportunity opp = createApprovalGivenOpportunity('iso@example.com');
        Test.setMock(HttpCalloutMock.class, new NoOpHttpMock());
        TVT_MultiOfferEmailService.send(
            opp.Id,
            new List<TVT_MultiOfferEmailService.ProgramSelection>{ flex },
            50000
        );
        Test.stopTest();

        Opportunity updated = [
            SELECT Flex_Offer_Rows__c FROM Opportunity WHERE Id = :opp.Id
        ];
        System.assertEquals(flex.rows[0], updated.Flex_Offer_Rows__c);
        clearMocks();
    }
}