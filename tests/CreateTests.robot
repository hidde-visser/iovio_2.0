*** Settings ***
Library                         RequestsLibrary
Library                         QForce
Library                         CopadoAI
Library                         ../resources/png_to_pdf_library.py
Library                         XML
Resource                        ../resources/CopadoAI.robot
Library                         ../resources/ObjectSanitizer.py
Resource                        ../resources/common_keywords.robot
Resource                        ../resources/MetadataRetrieval.robot
Library                         ../resources/DomParserLibrary.py
Library                         ../resources/ExplorationSessionLibrary.py
Suite Setup                     Initialize Salesforce Session

*** Variables ***
@{objects}                      Lead
${target_assistant_name}        Orchestrate Agent
${number_of_scenarios}          3

*** Test Cases ***
Test
    ${ts}=                      Get Current Date            result_format=%Y%m%d_%H%M%S
    ${screenshot_name}=         Set Variable                ${test_name}_failure_${ts}.png
    ${screenshot_path}=         Set Variable                ${OUTPUT_DIR}/${screenshot_name}

    # QWeb's LogScreenshot forces its own naming convention (screenshot-<test>-<uuid>.png).
    # We capture its returned path and copy it to our custom test-named path.
    ${qweb_screenshot}=         LogScreenshot
    Copy File                   ${qweb_screenshot}          ${screenshot_path}

    ${response}                 Prompt                      Can you read this screenshot ${screenshot_path}
    Log To Console              ${response}

    ${pdf_file}                 Set Variable                ${OUTPUT_DIR}/${test_name}_failure_${ts}.pdf

    Convert Png To Pdf          ${screenshot_path}          ${pdf_file}

Conversational AI Health Check
    [Documentation]             Feeds org data to the AI, asks for advice, and executes the results.

    # # 1. Fetch the Org Data (The script does this, not the AI)
    ${timestamp}=               Get Time                    format=%Y-%m-%dT%H%M%S
    ${config}=                  Build Org Contract Config                               ${objects}[0]
    ${raw_result}=              Execute Dynamic Operations                              ${config}
    ${obj_dict}=                Create Dictionary           Lead=${raw_result}
    ${clean_result}=            Sanitize Org Contract       ${obj_dict}

    ${meta_file}=               Set Variable                ${OUTPUT_DIR}/org_context_${timestamp}.json
    Create File                 ${meta_file}                ${clean_result}

    Initialize Copado AI Session
    ${TARGET_ASSISTANT_ID}=     Get Agent ID By Name        ${target_assistant_name}    ${CLEAN_WSPACE}

    ${DIALOGUE_ID}              Create Dialogue Thread      ${TARGET_ASSISTANT_ID}

    Log To Console              🧠 Giving the ${target_assistant_name} access to the org data...
    Attach Document To Dialogue                             ${meta_file}                ${DIALOGUE_ID}
    Verify Document Is Ready    org_context_${timestamp}.json                           ${DIALOGUE_ID}

    # 4. Formulate the Guardrail-Bypass Prompt
    Log To Console              💬 Asking the AI what we should test...
    ${prompt}=                  Catenate
    ...                         You are a Salesforce QA Architect. I have attached the metadata for my Salesforce org.\n
    ...                         Please perform a Health Check analysis on this metadata.\n
    ...                         Identify the ${number_of_scenarios} most critical test scenarios we should execute based on validation rules, required fields, and layouts.\n
    ...                         I understand that you must provide context and act as a knowledgeable mentor. Therefore, please explain your reasoning fully, but format your ENTIRE response as a structured JSON array.\n
    ...                         Place your detailed mentor explanation inside the "explanation" key for each scenario.\n
    ...                         You must use this exact JSON schema:\n
    ...                         [\n
    ...                         {\n
    ...                         "object_name": "Lead",\n
    ...                         "explanation": "Provide your detailed context and reasoning here...",\n
    ...                         "intent": "Create a new Lead filling out all required fields"\n
    ...                         }\n
    ...                         ]

    # 5. Send the Message (With explicit Document Processing Wait and Circuit Breaker)
    TRY
        Log To Console          ⏳ Giving the AI 60 seconds to index the metadata document...
        Sleep                   60s

        # FIX: Pass Dialogue ID as the first positional argument
        Wait Until Dialogue Is Idle                         ${DIALOGUE_ID}              max_attempts=12        poll_interval=5s

        Log To Console          💬 Sending prompt to agent...
        Send Message To Agent                               ${TARGET_ASSISTANT_ID}      ${DIALOGUE_ID}         ${prompt}                 max_retries=50
        ${ai_reply}=            Retrieve Agent Reply

    EXCEPT
        Log To Console          ⚠️ Agent thread seems locked/bricked. Initiating a new chat...

        ${DIALOGUE_ID}          Create Dialogue Thread      ${TARGET_ASSISTANT_ID}
        Attach Document To Dialogue                         ${meta_file}                ${DIALOGUE_ID}
        Verify Document Is Ready                            org_context_${timestamp}.json                      ${DIALOGUE_ID}

        Log To Console          ⏳ Giving the new thread 60 seconds to index the metadata document...
        Sleep                   60s

        # FIX: Pass Dialogue ID as the first positional argument here too
        Wait Until Dialogue Is Idle                         ${DIALOGUE_ID}              max_attempts=12        poll_interval=5s

        Send Message To Agent                               ${TARGET_ASSISTANT_ID}      ${DIALOGUE_ID}         ${prompt}                 max_retries=50
        ${ai_reply}=            Retrieve Agent Reply
    END

    # 6. Parse the AI's reply into a usable list
    ${test_scenarios}=          Extract Agent JSON Reply    ${ai_reply}
    Log To Console              🤖 The AI suggests we test: ${test_scenarios}

    # Initialize a collection to track defects/failures without halting the execution loop
    ${failed_scenarios}=        Create List

    # 7. Feed the AI's suggestions directly into your execution engine
    FOR                         ${scenario}                 IN                          @{test_scenarios}
        ${target_intent}=       Get From Dictionary         ${scenario}                 intent                 default=UNKNOWN_INTENT

        IF                      $target_intent == 'UNKNOWN_INTENT'
            Log To Console      ⚠️ Skipping scenario: AI generated an object without an 'intent' key.
            CONTINUE
        END

        Log To Console          \n======================================================
        Log To Console          🚀 Now Executing AI Suggestion: ${target_intent}
        Log To Console          ======================================================

        # Execute using a non-blocking TRY block to tolerate defects and allow loop completion
        TRY
            Run Agentic Test Scenario                       ${TARGET_ASSISTANT_ID}      ${target_intent}
        EXCEPT                  AS                          ${error_msg}
            Log To Console      ❌ Scenario Execution Failed: ${error_msg}
            Append To List      ${failed_scenarios}         Scenario: "${target_intent}" -> ${error_msg}
        END
    END

    # Final summary evaluation: fail the test suite if any potential defects were gathered
    ${num_failures}=            Get Length                  ${failed_scenarios}
    IF                          ${num_failures} > 0
        ${failure_summary}=     Catenate                    SEPARATOR=\n                @{failed_scenarios}
        Fail                    Autonomous orchestration finished with potential defects or script failures:\n${failure_summary}
    END