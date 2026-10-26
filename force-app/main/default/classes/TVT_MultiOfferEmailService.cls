/**
* TVT_MultiOfferEmailService.cls — Sends the combined Multiple Offers email.
*
 * Selects the Multi Offer EmailTemplate by Opportunity White Label using
 * Multi_Offer_Email_Template_Mapping__mdt.Approval_Template_ID__c. If no matching
 * mapping or template ID is configured, falls back to the EmailTemplate whose
 * DeveloperName is 'Approval_Multi_Offer'.
* Renders it natively via Messaging.renderStoredEmailTemplate (so existing Salesforce merge
* fields resolve normally). No placeholder tokens are added to the stored template — instead the
* rendered HTML is modified in memory only, anchored to markup the template already has: the
* "Paying Off" Positions box, every per-program offer section (".offer-section"/".offer-table"),
* and Required Documentation are all inserted together, in that order, right after the
* `<!-- OFFER_CONTENT -->` marker comment (which must sit between the Approved Amount hero and
* the company info bar in the template) — see insertOfferContent. "Approved Amount" itself
* (".amount-hero .value") is corrected in place — see replaceApprovedAmount. The stored
* EmailTemplate record itself is never written to.
*
* OWA resolution mirrors SendDeclineEmailForAutoDeclines: no dedicated OWA field, queried live by
* matching OrgWideEmailAddress.DisplayName to the Opportunity's White Label.
*
* @author Seda Ertugrul
* @date 2026-07-22
* @version 1.0
*/
public without sharing class TVT_MultiOfferEmailService {

    /** One program's checkboxed rows as selected (and possibly row-deleted) by the user in the LWC. */
    public class ProgramSelection {
        public String programLabel;
        /** Cosmetic display-name override (see TVT_MultiOfferController.saveProgramDisplayLabel) —
         * shown in the email instead of programLabel when set; programLabel itself is always the
         * real/internal name used for every lookup (Offer_Program_Config__mdt, ACCEPT-OFFER
         * subject, etc.), never this. Null if the rep never renamed this program. */
        public String displayLabel;
        public List<String> rows;
    }

    /** One existing MCA stacking position the rep left checked in the modal's Positions section —
     * shown to the ISO in the outgoing email so they know what else is already in this deal's stack. */
    public class PositionSelection {
        public Integer position;
        public String name;
        public Decimal buyoffAmount;
    }

    public class EmailServiceException extends Exception {}

    @TestVisible private static Map<String, Id> testTemplateMap;
    @TestVisible private static Boolean skipSendEmailInTest = false;

    /** Fallback template when no White Label-specific Multi Offer template ID is configured. */
    private static final String MULTI_OFFER_TEMPLATE_DEVELOPER_NAME = 'Approval_Multi_Offer';

    private static final Map<String, OrgWideEmailAddress> owaCache = new Map<String, OrgWideEmailAddress>();
    private static List<OrgWideEmailAddress> allOwas;

    private static Offer_Email_Address_Config__mdt addressConfigCache;

    /**
     * Default email configuration supplies optional BCC and the inbound Email Service
     * address used by SELECT links. White Label-specific CC is read separately from
     * Multi_Offer_Email_Template_Mapping__mdt; Opportunity CC and ISO Rep CC are preserved.
     * Each org maintains its own configuration values without environment-specific Apex.
     */
    private static Offer_Email_Address_Config__mdt addressConfig() {
        if (addressConfigCache == null) {
            addressConfigCache = [
                SELECT BCC_Email__c, Reply_To_Email__c, Portal_Base_URL__c
                FROM Offer_Email_Address_Config__mdt
                WHERE DeveloperName = 'Default'
                LIMIT 1
            ];
        }
        return addressConfigCache;
    }

    /**
     * Sends the combined Multiple Offers email for one Opportunity.
     *
     * @param opportunityId Opportunity to send from/for
     * @param selections    Selected program rows, exactly as left in the LWC (deleted rows already excluded)
     * @param advanceAmount New Dragin_Engine__Advance_Amount__c value from the modal — only written
     *                      to the record once the send succeeds, alongside the selected rows
     * @throws EmailServiceException If the Opportunity has no ISO email, or no template/OWA can be resolved
     */
    public static void send(Id opportunityId, List<ProgramSelection> selections, Decimal advanceAmount) {
        send(opportunityId, selections, advanceAmount, null);
    }

    /**
     * Overload accepting the Positions section's checked MCA stacking positions — rendered into
     * the email so the ISO sees what's already in the stack, and saved into
     * Multi_Offer_Send_Snapshot__c (merge-safe alongside "programLabels") for reference.
     */
    public static void send(
        Id opportunityId,
        List<ProgramSelection> selections,
        Decimal advanceAmount,
        List<PositionSelection> selectedPositions
    ) {
        send(opportunityId, selections, advanceAmount, selectedPositions, null);
    }

    /**
     * Overload additionally accepting the total of every position's manually-entered Buyoff
     * Amount (Positions tab) — written to Dragin_Engine__Payoff_or_Buy_Off__c once the send
     * succeeds, same "only written on success" timing as everything else in
     * updateOpportunityAfterSend.
     */
    public static void send(
        Id opportunityId,
        List<ProgramSelection> selections,
        Decimal advanceAmount,
        List<PositionSelection> selectedPositions,
        Decimal totalBuyoffAmount
    ) {
        Opportunity opp = [
            SELECT Id, Name, Dragin_Engine__White_Labels__c, Dragin_Engine__ISO_Email__c,
                   Dragin_Engine__CC_Address__c, Dragin_Engine__ISO_Rep_Email__c, Prepay_Config__c,
                   Multi_Offer_Send_Snapshot__c
            FROM Opportunity
            WHERE Id = :opportunityId
            WITH USER_MODE
            LIMIT 1
        ];

        if (String.isBlank(opp.Dragin_Engine__ISO_Email__c)) {
            throw new EmailServiceException('Opportunity has no ISO email to send the offer to: ' + opportunityId);
        }

        Id templateId = resolveTemplateId(opp.Dragin_Engine__White_Labels__c);
        OrgWideEmailAddress owa = resolveOwa(opp.Dragin_Engine__White_Labels__c);
        List<String> stips = TVT_MultiOfferController.getSelectedStips(opportunityId);

        Messaging.SingleEmailMessage mail = Messaging.renderStoredEmailTemplate(templateId, null, opportunityId);

        String htmlBody = mail.getHtmlBody() != null ? mail.getHtmlBody() : '';
        // renderStoredEmailTemplate merges "Approved Amount" from the Opportunity's CURRENT
        // (pre-send) Dragin_Engine__Advance_Amount__c — the new advanceAmount argument isn't
        // written to the record until updateOpportunityAfterSend(), which only runs after this
        // email is already sent. Without this, the email always shows the OLD amount (0 on a
        // first send). Same in-memory-only approach as the other content: never touches the
        // stored template, just corrects this one already-rendered value before sending.
        htmlBody = replaceApprovedAmount(htmlBody, advanceAmount);
        // Paying Off (deal-wide, so its own box rather than repeated per program) lands first,
        // right under Approved Amount; then every selected program's own offer section; then
        // Required Documentation last.
        String offerContentHtml = buildPositionsBlock(buildPositionsHtml(selectedPositions))
            + buildOfferTableHtml(selections, opp)
            + buildStipsHtml(stips);
        htmlBody = insertOfferContent(htmlBody, offerContentHtml);
        mail.setHtmlBody(htmlBody);

        mail.setToAddresses(new List<String>{ opp.Dragin_Engine__ISO_Email__c });
        mail.setCcAddresses(buildCcList(opp));
        String bccEmail = addressConfig().BCC_Email__c;
        if (String.isNotBlank(bccEmail)) {
            mail.setBccAddresses(new List<String>{ bccEmail });
        }
        if (owa != null) {
            mail.setOrgWideEmailAddressId(owa.Id);
        }
        mail.setWhatId(opportunityId);
        mail.setSaveAsActivity(true);

        if (Test.isRunningTest() && skipSendEmailInTest) {
            return;
        }
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });

        updateOpportunityAfterSend(opportunityId, selections, advanceAmount, selectedPositions, totalBuyoffAmount);
    }

    /**
     * Writes back exactly what was just sent — the rows the user left checked for each program,
     * plus the (possibly edited) advance amount and total Buyoff Amount — onto the Opportunity in
     * one DML. Rows: a program with no rows selected/sent gets its field cleared, since it means
     * nothing from that program is currently offered. Add another branch here when a new
     * "*_Offer_Rows__c" field/program is introduced.
     */
    private static void updateOpportunityAfterSend(
        Id opportunityId,
        List<ProgramSelection> selections,
        Decimal advanceAmount,
        List<PositionSelection> selectedPositions,
        Decimal totalBuyoffAmount
    ) {
        String flexValue = null;
        String primeValue = null;
        String primeWeeklyValue = null;
        String abMonthlyValue = null;
        String abPrimeValue = null;
        String bcPowerValue = null;
        String bcSilverValue = null;

        for (ProgramSelection selection : selections) {
            if (selection.rows == null || selection.rows.isEmpty()) {
                continue;
            }
            String joined = String.join(selection.rows, ';');
            if (selection.programLabel == 'Flex Program') {
                flexValue = joined;
            } else if (selection.programLabel == 'Prime Monthly') {
                primeValue = joined;
            } else if (selection.programLabel == 'Prime Weekly') {
                primeWeeklyValue = joined;
            } else if (selection.programLabel == 'AB Monthly') {
                abMonthlyValue = joined;
            } else if (selection.programLabel == 'AB Prime') {
                abPrimeValue = joined;
            } else if (selection.programLabel == 'BC Power') {
                bcPowerValue = joined;
            } else if (selection.programLabel == 'BC Silver') {
                bcSilverValue = joined;
            }
        }

        Opportunity oppUpdate = new Opportunity(
            Id = opportunityId,
            Flex_Offer_Rows__c = flexValue,
            Prime_Offer_Rows__c = primeValue,
            Prime_Weekly_Offer_Rows__c = primeWeeklyValue,
            AB_Monthly_Offer_Rows__c = abMonthlyValue,
            AB_Prime_Offer_Rows__c = abPrimeValue,
            BC_Power_Offer_Rows__c = bcPowerValue,
            BC_Silver_Offer_Rows__c = bcSilverValue,
            Dragin_Engine__Advance_Amount__c = advanceAmount,
            Dragin_Engine__Payoff_or_Buy_Off__c = totalBuyoffAmount,
            StageName = 'Approval Given',
            Dragin_Engine__Offer_Sent_DateTime__c = Datetime.now(),
            Multi_Offer_Send_Snapshot__c = buildSnapshotWithSelectedPositions(opportunityId, selectedPositions)
        );
        update as user oppUpdate;
    }

    /**
     * Merges the checked Positions into Multi_Offer_Send_Snapshot__c under "selectedPositions" —
     * read-modify-write so this never clobbers "programLabels" (written independently, and
     * immediately, by TVT_MultiOfferController.saveProgramDisplayLabel). Returns null (field left
     * untouched) if there's neither a prior snapshot nor any positions to save.
     */
    private static String buildSnapshotWithSelectedPositions(Id opportunityId, List<PositionSelection> selectedPositions) {
        Opportunity opp = [SELECT Multi_Offer_Send_Snapshot__c FROM Opportunity WHERE Id = :opportunityId LIMIT 1];
        Map<String, Object> snapshot = String.isBlank(opp.Multi_Offer_Send_Snapshot__c)
            ? new Map<String, Object>()
            : (Map<String, Object>) JSON.deserializeUntyped(opp.Multi_Offer_Send_Snapshot__c);

        if (selectedPositions == null || selectedPositions.isEmpty()) {
            return snapshot.isEmpty() ? null : JSON.serialize(snapshot);
        }

        List<Object> positions = new List<Object>();
        for (PositionSelection p : selectedPositions) {
            positions.add(new Map<String, Object>{
                'position' => p.position,
                'name' => p.name,
                'buyoffAmount' => p.buyoffAmount
            });
        }
        snapshot.put('selectedPositions', positions);
        return JSON.serialize(snapshot);
    }

    /**
     * Renders the checked Positions for the ISO as Name | Buyoff Amount `<tr>` rows — Contracts
     * only needs to know who's being paid off and how much, not the funded amount or remaining
     * balance. Returns bare rows (no `<table>`/wrapper) — buildPositionsBlock below wraps them in
     * the template's own ".details-grid" table, matching buildProgramTermsHtml's markup.
     */
    private static String buildPositionsHtml(List<PositionSelection> selectedPositions) {
        if (selectedPositions == null || selectedPositions.isEmpty()) {
            return '';
        }
        String html = '';
        for (PositionSelection p : selectedPositions) {
            html += '<tr>'
                + '<td style="color:#777777;font-size:13px;padding:2px 10px 2px 0;">' + escapeHtml(p.name) + '</td>'
                + '<td style="color:#1a1a1a;font-size:13px;font-weight:700;padding:2px 0;text-align:right;">' + formatCurrency(p.buyoffAmount) + '</td>'
                + '</tr>';
        }
        return html;
    }

    /** Blank instead of "$0.00" when a position's amount was never entered — a real, deliberate
     * $0 is rare enough here that treating null and 0 the same reads better than "$0.00" noise. */
    private static String formatCurrency(Decimal value) {
        return value == null ? '' : '$' + value.setScale(2).format();
    }

    /**
     * Wraps the checked Positions' `<tr>` rows in the template's own ".details-wrap"/".details-box"/
     * ".details-grid" markup — its own box, headed "Paying Off", deliberately SEPARATE from any
     * program's "Program Details" box since Buyoff/Positions is deal-wide, not program-specific
     * (it would otherwise repeat identically under every selected program). Returns '' when
     * there's nothing to show, so send() never inserts an empty box.
     */
    @TestVisible
    private static String buildPositionsBlock(String positionsRowsHtml) {
        if (String.isBlank(positionsRowsHtml)) {
            return '';
        }
        return '<div class="details-wrap" style="margin-top:16px;"><div class="details-box">'
            + '<span class="details-subhead">Paying Off</span>'
            + '<table class="details-grid" role="presentation" cellpadding="0" cellspacing="0">'
            + positionsRowsHtml
            + '</table>'
            + '</div></div>';
    }

    /**
     * Combines comma-separated Opportunity CC addresses, the ISO Rep email, and the
     * optional White Label-specific CC_Email__c from Multi_Offer_Email_Template_Mapping__mdt.
     */
    private static List<String> buildCcList(Opportunity opp) {
        List<String> ccAddresses = new List<String>();

        // Opportunity CC addresses
        if (String.isNotBlank(opp.Dragin_Engine__CC_Address__c)) {
            for (String cc : opp.Dragin_Engine__CC_Address__c.split(',')) {
                String trimmed = cc.trim();
                if (String.isNotBlank(trimmed)) {
                    ccAddresses.add(trimmed);
                }
            }
        }

        // ISO Representative CC
        if (String.isNotBlank(opp.Dragin_Engine__ISO_Rep_Email__c)) {
            ccAddresses.add(opp.Dragin_Engine__ISO_Rep_Email__c.trim());
        }

        // White Label-specific CC from Multi Offer metadata
        Multi_Offer_Email_Template_Mapping__mdt mapping =
            getMapping(opp.Dragin_Engine__White_Labels__c);

        if (mapping != null && String.isNotBlank(mapping.CC_Email__c)) {
            ccAddresses.add(mapping.CC_Email__c.trim());
        }

        return ccAddresses;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // TEMPLATE / OWA RESOLUTION — per-White-Label template mapping with default fallback;
    // OWA resolution continues to match the Opportunity's White Label.
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * Resolves a White Label-specific Multi Offer template ID from custom metadata.
     * Falls back to Approval_Multi_Offer if no matching mapping or template ID exists.
     * Retains the testTemplateMap override for unit tests.
     */
    private static Id resolveTemplateId(String whiteLabel) {
    if (Test.isRunningTest() && testTemplateMap != null) {
        String key = String.isBlank(whiteLabel) ? '' : whiteLabel;
        if (testTemplateMap.containsKey(key)) {
            return testTemplateMap.get(key);
        }
    }

    Multi_Offer_Email_Template_Mapping__mdt mapping = getMapping(whiteLabel);
    if (mapping != null && String.isNotBlank(mapping.Approval_Template_ID__c)) {
        try {
            return (Id) mapping.Approval_Template_ID__c.trim();
        } catch (Exception ex) {
            throw new EmailServiceException(
                'Invalid Multi Offer Approval Template ID for White Label: ' + whiteLabel
            );
        }
    }

    List<EmailTemplate> templates = [
        SELECT Id
        FROM EmailTemplate
        WHERE DeveloperName = :MULTI_OFFER_TEMPLATE_DEVELOPER_NAME
        LIMIT 1
    ];

    if (templates.isEmpty()) {
        throw new EmailServiceException(
            'No EmailTemplate found with DeveloperName = ' + MULTI_OFFER_TEMPLATE_DEVELOPER_NAME
        );
    }

    return templates[0].Id;
}
    
    /** Finds the White Label mapping by DeveloperName (spaces converted to underscores)
     * or by its exact MasterLabel; returns null when no record matches. */
    private static Multi_Offer_Email_Template_Mapping__mdt getMapping(String whiteLabel) {
    if (String.isBlank(whiteLabel)) {
        return null;
    }

    String developerName = whiteLabel.replace(' ', '_');

    for (Multi_Offer_Email_Template_Mapping__mdt mapping :
         Multi_Offer_Email_Template_Mapping__mdt.getAll().values()) {

        if (mapping.DeveloperName == developerName ||
            mapping.MasterLabel == whiteLabel) {
            return mapping;
        }
    }

    return null;
}
//////////

    private static OrgWideEmailAddress resolveOwa(String whiteLabel) {
        String key = String.isBlank(whiteLabel) ? '' : whiteLabel;
        if (owaCache.containsKey(key)) {
            return owaCache.get(key);
        }
        if (allOwas == null) {
            allOwas = [SELECT Id, Address, DisplayName FROM OrgWideEmailAddress];
        }

        OrgWideEmailAddress found = null;
        if (String.isNotBlank(whiteLabel)) {
            for (OrgWideEmailAddress owa : allOwas) {
                if (owa.DisplayName == whiteLabel) {
                    found = owa;
                    break;
                }
            }
        }
        if (found == null && !allOwas.isEmpty()) {
            found = allOwas[0];
        }

        owaCache.put(key, found);
        return found;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // DYNAMIC HTML — the two pieces native EmailTemplate merge fields cannot express
    // ─────────────────────────────────────────────────────────────────────────────

    /** Matches the outlined "SELECT" button in the design mockup. */
    private static final String SELECT_BUTTON_STYLE =
        'display:inline-block;border:1px solid #16944b;color:#16944b;font-size:12px;font-weight:700;'
        + 'letter-spacing:0.5px;padding:7px 18px;border-radius:4px;text-decoration:none;';

    /**
     * Builds one ".offer-section" block per selected program, reusing the template's own
     * ".offer-section" / ".offer-table-wrap" / ".offer-table" classes so it looks native to the
     * brand. Each row gets a "SELECT" button whose mailto: link points at this org's
     * Offer_Email_Address_Config__mdt.Default.Reply_To_Email__c (the TVT_OfferReplyEmailHandler
     * inbound Email Service address). The subject is machine-parseable
     * ("ACCEPT-OFFER:<oppId>:<program>:<row>"); the body is a fill-in-the-blank template asking
     * for the ISO's requested upsell % — this is how the ISO's own sell rate/commission gets
     * captured without an interactive form (see TVT_OfferReplyEmailHandler for the parsing side).
     *
     * Each row label (e.g. "1.30 buy rate | 32 weekly remits | 8 months") is split into 3
     * columns by position, but the 2nd/3rd column HEADERS switch based on the program's naming:
     * "Monthly"-named programs describe rows as "buy rate | X months | Y total remits" (term
     * before remits), every other program as "buy rate | X weekly remits | Y months" (remits
     * before term) — using fixed headers regardless would mislabel data for half the programs.
     */
    @TestVisible
    private static String buildOfferTableHtml(List<ProgramSelection> selections, Opportunity opp) {
        String replyToAddress = addressConfig().Reply_To_Email__c;
        if (replyToAddress == null) {
            replyToAddress = '';
        }
        Map<String, Object> programOverrides = parseProgramOverrides(opp.Multi_Offer_Send_Snapshot__c);
        String html = '';

        for (ProgramSelection selection : selections) {
            if (selection.rows == null || selection.rows.isEmpty()) {
                continue;
            }
            Offer_Program_Config__mdt programConfig = getProgramConfig(selection.programLabel);
            Decimal maxUpsellForBody = effectiveMaxUpsell(selection.programLabel, programConfig, programOverrides);
            String headerLabel = String.isNotBlank(selection.displayLabel) ? selection.displayLabel : selection.programLabel;

            Boolean isMonthlyFormat = selection.programLabel.contains('Monthly');
            String col2Header = isMonthlyFormat ? 'Term' : 'Weekly Remits';
            String col3Header = isMonthlyFormat ? 'Total Remits' : 'Term';

            html += '<div class="offer-section">';
            html += '<table class="offer-section-title-row" role="presentation" cellpadding="0" cellspacing="0">'
                + '<tr><td>' + escapeHtml(headerLabel) + ' Options</td>'
                + '<td class="right">Select one option to proceed</td></tr></table>';
            // table-layout:fixed + explicit widths on every cell (header AND body) — without
            // this, each column's width auto-sizes per row based on that row's own text length,
            // so columns visibly drift out of alignment from one row to the next.
            html += '<div class="offer-table-wrap"><table class="offer-table" role="presentation" cellpadding="0" cellspacing="0" style="table-layout:fixed;">';
            html += '<thead><tr>'
                + '<td style="width:28%;">Buy Rate</td>'
                + '<td style="width:24%;">' + col2Header + '</td>'
                + '<td style="width:24%;">' + col3Header + '</td>'
                + '<td style="width:24%;">Action</td>'
                + '</tr></thead><tbody>';
            for (String rowLabel : selection.rows) {
                List<String> parts = splitRowLabelParts(rowLabel);

                // Machine-parseable subject for TVT_OfferReplyEmailHandler: "ACCEPT-OFFER:<oppId>:<program>:<row>".
                // Uses the FULL original rowLabel (not the split parts) — TVT_OfferReplyEmailHandler's
                // buy-rate/remits/frequency parsing depends on that exact combined string.
                // mailto: query params need %20 for spaces, not "+" — mail clients don't decode
                // "+" back to space in mailto links the way browsers do for HTML form submissions,
                // so EncodingUtil.urlEncode's output must be corrected before use here.
                String subject = mailtoEncode(
                    'ACCEPT-OFFER:' + opp.Id + ':' + selection.programLabel + ':' + rowLabel
                );
                // No placeholder character (no "____") after the colon — some mail clients treat
                // runs of underscores as rich-text formatting markers and corrupt the plain-text
                // body when the user edits around them. The line is pre-filled with the program's
                // MAX allowed upsell (rather than left blank) — if the ISO forgets to touch this
                // reply entirely, extractUpsellPercent still finds a valid number instead of the
                // email silently failing to parse; if they want a different number they just
                // overwrite it before sending.
                String defaultUpsellText = maxUpsellForBody != null ? String.valueOf(maxUpsellForBody) : '';
                String maxUpsellNote = maxUpsellForBody != null
                    ? '\n(Maximum allowed for this program: ' + maxUpsellForBody + '%)' : '';
                String body = mailtoEncode(
                    '⚠️ ACTION REQUIRED — REVIEW YOUR % BELOW BEFORE SENDING ⚠️\n\n'
                    + 'Requested Upsell %: ' + defaultUpsellText + maxUpsellNote + '\n\n'
                    + 'Your final Sell Rate = Buy Rate + Requested Upsell % (cannot exceed the maximum shown above).\n\n'
                    + '❗ This defaults to the MAXIMUM allowed upsell. If you want a different number, replace it above before sending.\n\n'
                    + '🗑️ Please remove your email signature/logo from this reply before sending.'
                );
                String href = 'mailto:' + replyToAddress + '?subject=' + subject + '&body=' + body;

                html += '<tr>'
                    + '<td style="width:28%;padding:12px 16px;font-size:14px;font-weight:700;border-bottom:1px solid #ebebeb;">' + escapeHtml(parts[0]) + '</td>'
                    + '<td style="width:24%;padding:12px 16px;font-size:14px;border-bottom:1px solid #ebebeb;">' + escapeHtml(parts[1]) + '</td>'
                    + '<td style="width:24%;padding:12px 16px;font-size:14px;border-bottom:1px solid #ebebeb;">' + escapeHtml(parts[2]) + '</td>'
                    + '<td style="width:24%;padding:12px 16px;border-bottom:1px solid #ebebeb;text-align:right;">'
                    + '<a href="' + href + '" style="' + SELECT_BUTTON_STYLE + '">SELECT</a>'
                    + '</td>'
                    + '</tr>';
            }
            html += '</tbody></table></div>';
            html += buildProgramTermsHtml(headerLabel, selection.programLabel, opp.Prepay_Config__c, programOverrides);
            html += '</div>';
        }
        return html;
    }

    /** Splits a row label like "1.30 buy rate | 32 weekly remits | 8 months" into exactly 3
     * trimmed parts (padding with '' if the label doesn't have 3 "|"-separated segments), for
     * buildOfferTableHtml's 3-column layout. */
    private static List<String> splitRowLabelParts(String rowLabel) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(rowLabel)) {
            for (String part : rowLabel.split('\\|')) {
                parts.add(part.trim());
            }
        }
        while (parts.size() < 3) {
            parts.add('');
        }
        return parts;
    }

    /**
     * Renders one program's "Program Details" box — Program type, Origination Fee %, Max Upsell %
     * (from Offer_Program_Config__mdt), and Prepay Buy Rates (the Opportunity's actually-saved
     * Prepay_Config__c "Prepaids", shared across every program — see buildSharedPrepayRatesText).
     * "Paying Off" is deliberately NOT included here — that's deal-wide, not program-specific, so
     * it gets its own separate box (see buildPositionsBlock) instead of repeating per program.
     */
    private static String buildProgramTermsHtml(
        String displayLabel,
        String programLabel,
        String prepayConfigJson,
        Map<String, Object> programOverrides
    ) {
        Offer_Program_Config__mdt config = getProgramConfig(programLabel);
        String prepayText = buildSharedPrepayRatesText(prepayConfigJson);
        Decimal originationFee = effectiveOriginationFee(programLabel, config, programOverrides);
        Decimal maxUpsell = effectiveMaxUpsell(programLabel, config, programOverrides);

        // A real 2-column <table> (not inline <span>s separated by <br>) so the label column's
        // width is consistent down every row regardless of label text length — "Origination fee"
        // is longer than "Max upsell", so plain inline spans left each value starting at a
        // different horizontal position. Colors are inline (not the ".details-label"/".details-value"
        // classes) so they render consistently even in clients with partial <style> block support.
        String leftHtml = '<table role="presentation" cellpadding="0" cellspacing="0" style="border-collapse:collapse;">'
            + detailsRow('Program type', escapeHtml(displayLabel));
        if (originationFee != null) {
            leftHtml += detailsRow('Origination fee', originationFee + '%');
        }
        if (maxUpsell != null) {
            leftHtml += detailsRow('Max upsell', maxUpsell + '%');
        }
        leftHtml += '</table>';

        String rightHtml = '';
        if (String.isNotBlank(prepayText)) {
            rightHtml = '<span class="details-subhead">Prepay buy rates</span>' + buildPrepayListHtml(prepayText);
        }

        // NOT ".details-wrap" here — this box is nested inside ".offer-section", which already
        // has its own padding:0 36px, so adding ".details-wrap"'s padding on top of that made
        // the box narrower/more inset than the offer table above and Required Documentation
        // below it. A plain div (no side padding) keeps this box the same width as both.
        return '<div style="margin-top:8px;"><div class="details-box">'
            + '<span class="details-subhead">Program Details</span>'
            + '<table class="details-grid" role="presentation" cellpadding="0" cellspacing="0"><tr>'
            + '<td class="details-col-left">' + leftHtml + '</td>'
            + '<td>' + rightHtml + '</td>'
            + '</tr></table>'
            + '</div></div>';
    }

    /** One "Label      Value" row for buildProgramTermsHtml's left column — a real table row
     * (not inline spans) guarantees the value column starts at the same x-position on every
     * row, and inline colors guarantee consistent rendering across email clients. */
    private static String detailsRow(String label, String value) {
        return '<tr>'
            + '<td style="color:#777777;font-size:13px;padding:2px 10px 2px 0;white-space:nowrap;">' + label + '</td>'
            + '<td style="color:#1a1a1a;font-size:13px;font-weight:700;padding:2px 0;">' + value + '</td>'
            + '</tr>';
    }

    /** buildSharedPrepayRatesText returns one comma-joined string (e.g. "1.20 | 30 days, 1.25 |
     * 60 days") — split back into individual `.prepay-list` <li> items for proper list rendering. */
    private static String buildPrepayListHtml(String prepayText) {
        String html = '<ul class="prepay-list">';
        for (String item : prepayText.split(',\\s*')) {
            html += '<li>' + escapeHtml(item) + '</li>';
        }
        html += '</ul>';
        return html;
    }

    /**
     * Same source/priority as multipleOffersButton's _buildSharedPrepayText: prefers the
     * actually-saved Prepay_Config__c "Prepaids" (what the rep left checked in the Prepayment
     * section last time they hit Save), falling back to the raw Prepay_Default__mdt term list
     * only if nothing has ever been saved for this Opportunity. Not program-specific — every
     * program's block gets this same line.
     */
    private static String buildSharedPrepayRatesText(String prepayConfigJson) {
        if (String.isNotBlank(prepayConfigJson)) {
            try {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(prepayConfigJson);
                List<Object> prepaids = (List<Object>) parsed.get('Prepaids');
                if (prepaids != null && !prepaids.isEmpty()) {
                    List<String> parts = new List<String>();
                    for (Object entry : prepaids) {
                        Map<String, Object> m = (Map<String, Object>) entry;
                        parts.add(m.get('buyRate') + ' | ' + m.get('days') + ' days');
                    }
                    return String.join(parts, ', ');
                }
            } catch (Exception ex) {
                // Malformed JSON — fall through to the Prepay_Default__mdt fallback below.
            }
        }

        List<String> parts = new List<String>();
        for (Prepay_Default__mdt def : [
            SELECT MasterLabel, Min_Buy_Rate__c
            FROM Prepay_Default__mdt
            ORDER BY MasterLabel ASC NULLS LAST
        ]) {
            parts.add(def.Min_Buy_Rate__c + ' | ' + def.MasterLabel + ' days');
        }
        return String.join(parts, ', ');
    }

    private static final Map<String, Offer_Program_Config__mdt> programConfigCache
        = new Map<String, Offer_Program_Config__mdt>();

    /** Offer_Program_Config__mdt.DeveloperName mirrors the program label with spaces replaced by underscores. */
    private static Offer_Program_Config__mdt getProgramConfig(String programLabel) {
        String developerName = programLabel.replace(' ', '_');
        if (programConfigCache.containsKey(developerName)) {
            return programConfigCache.get(developerName);
        }
        List<Offer_Program_Config__mdt> configs = [
            SELECT Max_Upsell_Percent__c, Origination_Fee_Percent__c, Prepay_Rates_JSON__c
            FROM Offer_Program_Config__mdt
            WHERE DeveloperName = :developerName
            LIMIT 1
        ];
        Offer_Program_Config__mdt found = configs.isEmpty() ? null : configs[0];
        programConfigCache.put(developerName, found);
        return found;
    }

    /**
     * Reads the "programOverrides" key from this Opportunity's Multi_Offer_Send_Snapshot__c —
     * a rep's per-deal edit of Origination Fee %/Max Upsell % for one program (see
     * TVT_MultiOfferController.saveProgramOverride), which takes priority over
     * Offer_Program_Config__mdt's org-wide default. Malformed/blank JSON is swallowed so a send
     * never fails because of this — it just falls back to the CMDT defaults everywhere.
     */
    private static Map<String, Object> parseProgramOverrides(String snapshotJson) {
        if (String.isBlank(snapshotJson)) {
            return new Map<String, Object>();
        }
        try {
            Map<String, Object> snapshot = (Map<String, Object>) JSON.deserializeUntyped(snapshotJson);
            Map<String, Object> overrides = (Map<String, Object>) snapshot.get('programOverrides');
            return overrides != null ? overrides : new Map<String, Object>();
        } catch (Exception ex) {
            return new Map<String, Object>();
        }
    }

    /** The deal-specific override (if the rep edited it for this program) always wins over
     * Offer_Program_Config__mdt's org-wide default — used for BOTH what's shown to the ISO
     * (offer table/Program Details box) and, on the reply side, what TVT_OfferReplyEmailHandler
     * enforces as the accept cap, so the two never disagree. */
    private static Decimal effectiveMaxUpsell(String programLabel, Offer_Program_Config__mdt config, Map<String, Object> programOverrides) {
        Object overrideVal = getOverrideField(programOverrides, programLabel, 'maxUpsellPercent');
        if (overrideVal != null) {
            return toDecimal(overrideVal);
        }
        return config != null ? config.Max_Upsell_Percent__c : null;
    }

    private static Decimal effectiveOriginationFee(String programLabel, Offer_Program_Config__mdt config, Map<String, Object> programOverrides) {
        Object overrideVal = getOverrideField(programOverrides, programLabel, 'originationFeePercent');
        if (overrideVal != null) {
            return toDecimal(overrideVal);
        }
        return config != null ? config.Origination_Fee_Percent__c : null;
    }

    private static Object getOverrideField(Map<String, Object> programOverrides, String programLabel, String fieldName) {
        Map<String, Object> forProgram = (Map<String, Object>) programOverrides.get(programLabel);
        return forProgram != null ? forProgram.get(fieldName) : null;
    }

    /** JSON.deserializeUntyped() always returns numbers as Double, never Decimal — a direct
     * (Decimal) cast throws a TypeException, so values from programOverrides must be converted
     * through String rather than cast directly. */
    private static Decimal toDecimal(Object value) {
        if (value == null) {
            return null;
        }
        return Decimal.valueOf(String.valueOf(value));
    }

    /** EncodingUtil.urlEncode encodes spaces as "+" (form-encoding style); mailto: query params
     * need "%20" instead, since mail clients treat "+" as a literal character, not a decoded space. */
    private static String mailtoEncode(String value) {
        return EncodingUtil.urlEncode(value, 'UTF-8').replace('+', '%20');
    }

    /**
     * Renders the shared stips list once — never repeated per program — reusing the template's
     * own ".docs-wrap"/".docs-grid"/".box" checkbox-grid markup, 2 stips per row (matches
     * ".docs-grid td { width:50% }").
     */
    private static String buildStipsHtml(List<String> stips) {
        if (stips == null || stips.isEmpty()) {
            return '';
        }
        String html = '<div class="docs-wrap"><span class="docs-title">Required Documentation</span>'
            + '<table class="docs-grid" role="presentation" cellpadding="0" cellspacing="0">';
        for (Integer i = 0; i < stips.size(); i += 2) {
            html += '<tr><td><span class="box"></span>' + escapeHtml(stips[i]) + '</td>';
            html += (i + 1 < stips.size())
                ? '<td><span class="box"></span>' + escapeHtml(stips[i + 1]) + '</td>'
                : '<td></td>';
            html += '</tr>';
        }
        html += '</table></div>';
        return html;
    }

    private static String escapeHtml(String value) {
        return value == null ? '' : value.escapeHtml4();
    }

    /**
     * Replaces the "Approved Amount" hero value (".amount-hero .value") with advanceAmount, in
     * the rendered copy only. See the call site in send() for why the merge-field-rendered value
     * can't be trusted here. Non-throwing fallback (html unchanged) if either marker is missing.
     */
    @TestVisible
    private static String replaceApprovedAmount(String html, Decimal advanceAmount) {
        String heroMarker = 'class="amount-hero"';
        Integer heroIdx = html.indexOf(heroMarker);
        if (heroIdx < 0 || advanceAmount == null) {
            return html;
        }
        String valueMarker = 'class="value"';
        Integer valueClassIdx = html.indexOf(valueMarker, heroIdx);
        if (valueClassIdx < 0) {
            return html;
        }
        Integer contentStart = html.indexOf('>', valueClassIdx) + 1;
        Integer contentEnd = html.indexOf('</span>', contentStart);
        if (contentEnd < 0) {
            return html;
        }
        String formatted = '$' + advanceAmount.setScale(2).format();
        return html.substring(0, contentStart) + formatted + html.substring(contentEnd);
    }

    /**
     * Inserts the "Paying Off" Positions box, every per-program offer section, and Required
     * Documentation together, right after the `<!-- OFFER_CONTENT -->` marker comment (which
     * must sit between the Approved Amount hero and the company info bar in this template).
     * Non-throwing fallback (html unchanged) if the marker is missing, so a template edit
     * degrades to "offer content missing" instead of a hard failure.
     */
    @TestVisible
    private static String insertOfferContent(String html, String offerContentHtml) {
        String marker = '<!-- OFFER_CONTENT -->';
        Integer idx = html.indexOf(marker);
        if (idx < 0) {
            return html;
        }
        Integer insertAt = idx + marker.length();
        return html.substring(0, insertAt) + offerContentHtml + html.substring(insertAt);
    }
}