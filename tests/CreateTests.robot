*** Settings ***
Library                         RequestsLibrary
Library                         QForce
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

*** Test Cases ***
Conversational AI Health Check
    [Documentation]             Feeds org data to the AI, asks for advice, and executes the results.

    # 1. Fetch the Org Data (The script does this, not the AI)
    ${ts}=                      Get Time                    format=%Y-%m-%dT%H%M%S
    ${config}=                  Build Org Contract Config                               Lead                        # You can expand this to multiple objects
    ${result}=                  Execute Dynamic Operations                              ${config}
    ${meta_file}=               Set Variable                ${OUTPUT_DIR}/org_context_${ts}.json
    Create File                 ${meta_file}                ${result}

    # 2. Setup the AI Dialogue
    Initialize Copado AI Session
    ${TARGET_ASSISTANT_ID}=     Get Agent ID By Name        Orchestrate Agent           ${CLEAN_WSPACE}
    Create Dialogue Thread      ${TARGET_ASSISTANT_ID}

    # 3. Give the AI the Org Context
    Log To Console              🧠 Giving the Orchestrate Agent access to the org data...
    Attach Document To Dialogue                             ${meta_file}
    Verify Document Is Ready    org_context_${ts}.json

    # 4. Use your suggested keywords to Ask the AI what to test
    Log To Console              💬 Asking the AI what we should test...
    ${prompt}=                  Catenate
    ...                         You are a Salesforce QA Architect. I have attached the metadata for my Salesforce org.
    ...                         Please perform a Health Check analysis on this metadata.
    ...                         Identify the 3 most critical test scenarios we should execute based on validation rules, required fields, and layouts.
    ...                         You MUST reply ONLY with a JSON array matching this exact schema:
    ...                         [
    ...                         { "intent": "Create a new Lead filling out all required fields to bypass validation rule X" }
    ...                         ]

    Send Message To Agent       ${TARGET_ASSISTANT_ID}      ${prompt}
    ${ai_reply}=                Retrieve Agent Reply

    # 5. Parse the AI's reply into a usable list
    ${test_scenarios}=          Extract Agent JSON Reply    ${ai_reply}
    Log To Console              🤖 The AI suggests we test: ${test_scenarios}

    # 6. Feed the AI's suggestions directly into your execution engine
    FOR                         ${scenario}                 IN                          @{test_scenarios}
        ${target_intent}=       Get From Dictionary         ${scenario}                 intent

        Log To Console          🚀 Now Executing AI Suggestion: ${target_intent}
        Run Agentic Test Scenario                           ${TARGET_ASSISTANT_ID}      ${target_intent}            ${meta_file}
    END





















MyTestCase
    ${all_results}=             Create Dictionary

    ${ts}=                      Get Time                    format=%Y-%m-%dT%H%M%S
    FOR                         ${object}                   IN                          @{objects}
        LogToConsole            Starting with object: ${object}
        ${config}=              Build Org Contract Config                               ${object}
        ${result}=              Execute Dynamic Operations                              ${config}
        Set To Dictionary       ${all_results}              ${object}                   ${result}
    END
    ${clean}=                   Sanitize Org Contract       ${all_results}
    Create File                 ${OUTPUT_DIR}/objects_${ts}.json                        ${clean}


    Initialize Copado AI Session
    ${TARGET_ASSISTANT_ID}=     Get Agent ID By Name        Orchestrate Agent           ${CLEAN_WSPACE}
    Create Dialogue Thread      ${TARGET_ASSISTANT_ID}
    Attach Document To Dialogue                             ${OUTPUT_DIR}/objects_${ts}.json
    ${doc}                      Verify Document Is Ready    objects_${ts}.json
    Send Message To Agent       ${TARGET_ASSISTANT_ID}      Tell me the exact layout, section by section, field by field, their drop down values, data types and validation rules they follow. I have attached a .json file that contains all relevent layout and metatadata to ensure accuracy. Review objects_\${ts}.json file that has been uploaded before generating any steps.
    ${ai_reply}=                Retrieve Agent Reply
    ${clean_steps}=             Extract And Sanitize Robot Script                       ${ai_reply}
    ${ai_reply}=                Retrieve Agent Reply
    Log To Console              ${ai_reply}












Build My Test Agentically
    [Documentation]             Kick off the AI test builder
    Initialize Copado AI Session
    Attach Document To Dialogue                             ${OUTPUT_DIR}/objects_${ts}.json
    ${TARGET_ASSISTANT_ID}=     Get Agent ID By Name        Orchestrate Agent           ${CLEAN_WSPACE}
    Create Dialogue Thread      ${TARGET_ASSISTANT_ID}

    # 1. Define your intent hardcoded for testing
    ${my_intent}=               Set Variable                Create a test that creates a new lead

    # 2. Get your AI Assistant ID (using your existing keyword)
    ${assistant_id}=            Get Agent ID By Name        Orchestrate Agent           ${CLEAN_WSPACE}

    # 3. Fire the Orchestrator!
    Run Agentic Test Scenario                               ${assistant_id}             ${my_intent}






    ${body_html}=               Get Attribute               //body                      outerHTML
    ${json_output}=             Parse Elements From HTML    ${body_html}









    # ── POST-EXECUTION AUDIT LOGGING ────────────────────────────────────────

    # A: Every step the AI proposed across all turns
    ${all_proposed}=            Get All Proposed Steps
    Log To Console              📋 ALL PROPOSED STEPS (${all_proposed.__len__()} total):
    FOR                         ${step}                     IN                          @{all_proposed}
        Log To Console          → ${step}
    END

    # B: Steps that passed without a CRT error
    ${passed}=                  Get Execution History Passed
    Log To Console              ✅ PASSED STEPS (${passed.__len__()} total):
    FOR                         ${step}                     IN                          @{passed}
        Log To Console          → ${step}
    END

    # C: Steps that threw a CRT error
    ${failed}=                  Get Execution History Failed
    Log To Console              ❌ FAILED STEPS (${failed.__len__()} total):
    FOR                         ${step}                     IN                          @{failed}
        Log To Console          → ${step}
    END

    # D: The final golden path to be saved as the real test asset
    ${golden}=                  Get Golden Path Script
    Log To Console              🏆 GOLDEN PATH SCRIPT (${golden.__len__()} total):
    FOR                         ${step}                     IN                          @{golden}
        Log To Console          → ${step}
    END


TestClass
    Initialize Copado AI Session
    # Log To Console            Assistant: ${full_data['assistant_id']}
    # Log To Console            First message role: ${DIALOGUE_MESSAGES[0]['role']}
    ${dialogue_data}=           Read Dialogue With Messages                             7774bcbc-cbe6-4ff2-ab47-65b59188adbc

    Log To Console              ${dialogue_data}

    Extract Agent JSON Reply    ${dialogue_data}
    ${dialogue_data}=           Read Dialogue With Messages                             5966692b-50b7-409b-812d-7e7fb6d1b0d4

    ${ai_reply}=                Retrieve Agent Reply
    ${Json}=                    Extract Agent JSON Reply    ${ai_reply}

    Log To Console              ${ai_reply}
    Log To Console              ${Json}