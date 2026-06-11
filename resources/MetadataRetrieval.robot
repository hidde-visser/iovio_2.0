*** Settings ***
Documentation             Example resource file with custom keywords. NOTE: Some keywords below may need
...                       minor changes to work in different instances.
Library                   QForce
Library                   String
Library                   DateTime
Library                         RequestsLibrary
Library                         Collections

*** Variables ***
# IMPORTANT: Please read the readme.txt to understand needed variables and how to handle them!!
${BROWSER}                chrome

*** Keywords ***

#══════════════════════════════════════════════════════════════════════════════
# SUITE INITIALIZATION
#══════════════════════════════════════════════════════════════════════════════
Initialize Salesforce Session
    [Documentation]    Authenticates via JWT and caches token and instance URL as suite-level variables
    ${token}=           JwtAuthenticate    ${client_id}    ${username}    ${server_key}
    ${instanceUrl}=     Get Instance Url
    Set Suite Variable    ${SUITE_TOKEN}           ${token}
    Set Suite Variable    ${SUITE_INSTANCE_URL}    ${instanceUrl}
    Set Library Search Order                          QForce    QWeb
    Open Browser          about:blank                 ${BROWSER}
    SetConfig             LineBreak                   ${EMPTY}               #\ue000
    Evaluate              random.seed()               random                 # initialize random generator
    SetConfig             DefaultTimeout              10s                    #sometimes salesforce is slow
    # adds a delay of 0.3 between keywords. This is helpful in cloud with limited resources.
    SetConfig             Delay                       0.1
    JwtLogin
#══════════════════════════════════════════════════════════════════════════════
# MAIN ORCHESTRATION KEYWORD
#══════════════════════════════════════════════════════════════════════════════
Build Org Contract Config
    [Documentation]    Builds a fully dynamic Execute Dynamic Operations config
    ...                for any Salesforce object. Only ${file_name} needs to change.
    [Arguments]    ${object_name}
    ${config}=    Evaluate    json.loads("""{"operations":[{"id":"describe","type":"REST","method":"GET","endpoint":"/services/data/v65.0/sobjects/${object_name}/describe"},{"id":"activeRecordTypes","type":"SOQL","query":"SELECT Id, Name, DeveloperName, IsActive FROM RecordType WHERE SobjectType = '${object_name}' AND IsActive = true"},{"id":"validationRules","type":"TOOLING","action":"query","query":"SELECT Id, Active, Description, ErrorMessage, ErrorDisplayField FROM ValidationRule WHERE EntityDefinitionId = '${object_name}'"},{"id":"apexTriggers","type":"TOOLING","action":"query","query":"SELECT Id, Name, TableEnumOrId, Status, Body FROM ApexTrigger WHERE TableEnumOrId = '${object_name}'"},{"id":"objectInfo","type":"REST","method":"GET","endpoint":"/services/data/v65.0/ui-api/object-info/${object_name}"},{"id":"layout","type":"FOREACH","items":"{activeRecordTypes.records}","itemVar":"rt","keyTemplate":"layout_{rt.DeveloperName}","dependsOn":["activeRecordTypes"],"operation":{"type":"REST","method":"GET","endpoint":"/services/data/v65.0/ui-api/layout/${object_name}?recordTypeId={rt.Id}&layoutType=Full&mode=Edit"}},{"id":"picklist","type":"FOREACH","items":"{activeRecordTypes.records}","itemVar":"rt","keyTemplate":"picklist_{rt.DeveloperName}","dependsOn":["activeRecordTypes"],"operation":{"type":"REST","method":"GET","endpoint":"/services/data/v65.0/ui-api/object-info/${object_name}/picklist-values/{rt.Id}"}},{"id":"sampleRecords","type":"SOQL","query":"SELECT Id, Name, OwnerId, RecordTypeId FROM ${object_name} ORDER BY CreatedDate DESC LIMIT 5"}]}""")    json
    RETURN    ${config}
#══════════════════════════════════════════════════════════════════════════════
# MAIN ORCHESTRATION KEYWORD
#══════════════════════════════════════════════════════════════════════════════
Execute Dynamic Operations
    [Documentation]    Execute multiple Salesforce operations dynamically with error handling

    [Arguments]    ${config}

    # ═══════════════════════════════════════════════════════════
    # STEP 1: Validate configuration (catch JSON parsing errors)
    # ═══════════════════════════════════════════════════════════
    TRY
        ${operations}=    Get From Dictionary    ${config}    operations
    EXCEPT    AS    ${error}
        Log To Console    ❌ Invalid configuration: ${error}
        ${errorResult}=    Create Dictionary
        ...    _error=${True}
        ...    _errorMessage=Invalid JSON configuration: ${error}
        RETURN    ${errorResult}
    END

    Log To Console    🔧 Executing ${operations.__len__()} operation(s)

    # Storage for operation results
    ${results}=    Create Dictionary
    ${errors}=     Create Dictionary

    # ═══════════════════════════════════════════════════════════
    # STEP 2: Execute each operation
    # ═══════════════════════════════════════════════════════════
    FOR    ${op}    IN    @{operations}
        ${opId}=      Get From Dictionary    ${op}    id
        ${opType}=    Get From Dictionary    ${op}    type

        Log To Console    \n▶ Executing: ${opId} (${opType})

        # Check dependencies
        ${dependsOn}=    Get From Dictionary    ${op}    dependsOn    default=${EMPTY}

        ${hasDeps}=    Evaluate    len($dependsOn) > 0 if isinstance($dependsOn, list) else bool($dependsOn)

        IF    ${hasDeps}
            ${canExecute}=    Check Dependencies Met    ${dependsOn}    ${results}    ${errors}    ${operations}
        ELSE
            ${canExecute}=    Set Variable    ${True}
        END

        IF    not ${canExecute}
            Log To Console    ⚠ Skipping ${opId} - dependency failed
            Set To Dictionary    ${errors}    ${opId}    Dependency not met: ${dependsOn}
            CONTINUE
        END

        # Execute based on type (with error handling)
        TRY
            IF    '${opType}' == 'SOQL'
                ${result}=    Execute SOQL Operation            ${op}    ${results}
            ELSE IF    '${opType}' == 'REST'
                ${result}=    Execute REST Operation            ${op}    ${results}
            ELSE IF    '${opType}' == 'TOOLING'
                ${result}=    Execute Tooling Operation         ${op}    ${results}
            ELSE IF    '${opType}' == 'APEX'
                ${result}=    Execute Apex Operation            ${op}    ${results}
            ELSE IF    '${opType}' == 'BULK'
                ${result}=    Execute Bulk Operation            ${op}    ${results}
            ELSE IF    '${opType}' == 'BATCH_STATUS'
                ${result}=    Execute Batch Status Operation    ${op}    ${results}
            ELSE IF    '${opType}' == 'FOREACH'
                ${foreachResult}=    Execute Foreach Operation    ${op}    ${results}
                # Merge all child results into the main results dict
                FOR    ${childId}    IN    @{foreachResult.keys()}
                    ${childData}=    Get From Dictionary    ${foreachResult}    ${childId}
                    Set To Dictionary    ${results}    ${childId}    ${childData}
                END
                # Set a summary result under the FOREACH op's own id
                ${result}=    Set Variable    ${foreachResult}
            ELSE
                Fail    Unknown operation type: ${opType}
            END

            # Store successful result
            Set To Dictionary    ${results}    ${opId}    ${result}
            Log To Console    ✅ ${opId} completed successfully

        EXCEPT    AS    ${error}
            Log To Console    ❌ ${opId} failed: ${error}
            Set To Dictionary    ${errors}    ${opId}    ${error}
            # Continue with remaining operations
        END
    END

    # ═══════════════════════════════════════════════════════════
    # STEP 3: Add error summary to results
    # ═══════════════════════════════════════════════════════════
    ${errorCount}=    Get Length    ${errors}
    IF    ${errorCount} > 0
        Set To Dictionary    ${results}    _errors    ${errors}
        Log To Console    \n⚠ ${errorCount} operation(s) failed
    END

    # ═══════════════════════════════════════════════════════════
    # STEP 4: Return full results as JSON
    # ═══════════════════════════════════════════════════════════
    ${finalResult}=    Evaluate    json.dumps($results, indent=2)    json

    RETURN    ${finalResult}

#══════════════════════════════════════════════════════════════════════════════
# OPERATION EXECUTION KEYWORDS
#══════════════════════════════════════════════════════════════════════════════
Execute SOQL Operation
    [Documentation]    Executes a SOQL query with error handling

    [Arguments]    ${op}    ${previousResults}

    ${query}=    Get From Dictionary    ${op}    query

    # ✅ Resolve variables from previous operations
    ${query}=    Resolve Variables In String    ${query}    ${previousResults}

    Log To Console    📝 Query: ${query}

    # ✅ Wrap query execution in TRY/EXCEPT
    TRY
        ${result}=    Query Records    ${query}
    EXCEPT    AS    ${error}
        # Create error response structure
        ${result}=    Create Dictionary
        ...    _error=${True}
        ...    _errorMessage=${error}
        ...    totalSize=0
        ...    records=@{EMPTY}
        Log To Console    ❌ Query failed: ${error}
        # Re-raise to be caught by main orchestration
        Fail    ${error}
    END

    ${recordCount}=    Get From Dictionary    ${result}    totalSize
    Log To Console    📊 Retrieved ${recordCount} record(s)

    RETURN    ${result}

Execute REST Operation
    [Arguments]    ${op}    ${results}

    ${method}=      Get From Dictionary    ${op}    method
    ${endpoint}=    Get From Dictionary    ${op}    endpoint
    ${body}=        Get From Dictionary    ${op}    body    default=${EMPTY}

    # Resolve variable placeholders in endpoint
    ${endpoint}=    Resolve Variables In String    ${endpoint}    ${results}

    # Resolve variable placeholders in body (if present)
    ${hasBody}=    Run Keyword And Return Status    Should Not Be Empty    ${body}

    IF    ${hasBody}
        ${bodyIsDict}=    Evaluate    isinstance($body, dict)

        IF    ${bodyIsDict}
            ${bodyJson}=      Evaluate    json.dumps($body)    json
            ${resolvedJson}=  Resolve Variables In String    ${bodyJson}    ${results}
            ${body}=          Evaluate    json.loads('''${resolvedJson}''')    json
        ELSE
            ${body}=    Resolve Variables In String    ${body}    ${results}
        END
    END

    ${headers}=    Create Dictionary
    ...    Authorization=Bearer ${SUITE_TOKEN}
    ...    Content-Type=application/json

    ${fullUrl}=    Set Variable    ${SUITE_INSTANCE_URL}${endpoint}

    Log To Console    🌐 ${method} ${endpoint}

    # ✅ Wrap execution in TRY/EXCEPT
    TRY
        ${result}=    Run Keyword If    '${method}' == 'GET'
        ...    Execute GET Request    ${fullUrl}    ${headers}
        ...    ELSE IF    '${method}' == 'POST'
        ...    Execute POST Request    ${fullUrl}    ${body}    ${headers}
        ...    ELSE IF    '${method}' == 'PATCH'
        ...    Execute PATCH Request    ${fullUrl}    ${body}    ${headers}
        ...    ELSE IF    '${method}' == 'DELETE'
        ...    Execute DELETE Request    ${fullUrl}    ${headers}
        ...    ELSE
        ...    Fail    Unsupported HTTP method: ${method}
    EXCEPT    AS    ${error}
        # Create error result structure
        ${result}=    Create Dictionary
        ...    _error=${True}
        ...    _errorMessage=${error}
        Log To Console    ❌ Request failed: ${error}
        # Re-raise to be caught by main orchestration
        Fail    ${error}
    END

    RETURN    ${result}

Execute Tooling Operation
    [Documentation]    Execute Tooling API operations (describe, query, etc.)
    [Arguments]    ${op}    ${results}

    ${action}=    Get From Dictionary    ${op}    action
    ${sobject}=   Get From Dictionary    ${op}    sobject    default=${EMPTY}

    ${headers}=    Create Dictionary
    ...    Authorization=Bearer ${SUITE_TOKEN}
    ...    Content-Type=application/json

    # Build endpoint based on action
    IF    '${action}' == 'describe'
        ${endpoint}=    Set Variable    /services/data/v65.0/tooling/sobjects/${sobject}/describe
        ${method}=      Set Variable    GET
    ELSE IF    '${action}' == 'query'
        ${query}=         Get From Dictionary    ${op}    query
        ${query}=         Resolve Variables In String    ${query}    ${results}
        ${encodedQuery}=  Evaluate    __import__('urllib').parse.quote($query)
        ${endpoint}=      Set Variable    /services/data/v65.0/tooling/query/?q=${encodedQuery}
        ${method}=        Set Variable    GET
    ELSE
        Fail    Unsupported Tooling action: ${action}
    END

    ${fullUrl}=    Set Variable    ${SUITE_INSTANCE_URL}${endpoint}

    Log To Console    🔧 TOOLING ${action} ${sobject}

    # Execute the request
    ${response}=    RequestsLibrary.GET    url=${fullUrl}    headers=${headers}    expected_status=any
    ${result}=      Parse HTTP Response    ${response}

    # ✅ Check if response has error flag
    ${hasError}=    Run Keyword And Return Status
    ...    Dictionary Should Contain Key    ${result}    _error

    IF    ${hasError}
        ${errorMsg}=    Get From Dictionary    ${result}    _errorMessage
        Fail    ${errorMsg}
    END

    RETURN    ${result}

#══════════════════════════════════════════════════════════════════════════════
# HTTP REQUEST HELPERS
#══════════════════════════════════════════════════════════════════════════════
Resolve Variables In String
    [Documentation]    Resolves {op.field} placeholders using the results dict.
    ...                Skips resolution entirely if text contains no placeholders.
    [Arguments]    ${text}    ${results}

    # Fast path — if no placeholders exist, return immediately (avoids all eval issues)
    ${has_placeholder}=    Run Keyword And Return Status    Should Match Regexp    ${text}    \\{[A-Za-z_][^}]*\\}
    IF    not ${has_placeholder}
        RETURN    ${text}
    END

    # Slow path — resolve placeholders one at a time using RF keywords only
    ${resolved}=    Set Variable    ${text}
    ${matches}=     Get Regexp Matches    ${resolved}    \\{([A-Za-z_][^}]*)\\}    1
    FOR    ${path}    IN    @{matches}
        ${parts}=       Evaluate    [p for p in __import__('re').split(r'[.\\[\\]]', '${path}') if p]
        ${value}=       Set Variable    ${results}
        FOR    ${part}    IN    @{parts}
            ${is_int}=    Run Keyword And Return Status    Should Match Regexp    ${part}    ^\\d+$
            IF    ${is_int}
                ${value}=    Evaluate    ${value}[${part}]
            ELSE
                ${value}=    Get From Dictionary    ${value}    ${part}
            END
        END
        ${value_str}=   Convert To String    ${value}
        ${resolved}=    Replace String    ${resolved}    {${path}}    ${value_str}
    END

    RETURN    ${resolved}

Execute GET Request
    [Arguments]    ${url}    ${headers}

    ${response}=    GET    ${url}    headers=${headers}    expected_status=any
    ${result}=      Parse HTTP Response    ${response}

    # ✅ Check for error flag instead of failing
    ${hasError}=    Run Keyword And Return Status
    ...    Dictionary Should Contain Key    ${result}    _error

    IF    ${hasError}
        ${errorMsg}=    Get From Dictionary    ${result}    _errorMessage
        Fail    ${errorMsg}
    ELSE
        Log To Console    ✓ Success (${response.status_code})
    END

    RETURN    ${result}

Execute POST Request
    [Arguments]    ${url}    ${body}    ${headers}

    ${hasBody}=    Run Keyword And Return Status    Should Not Be Empty    ${body}

    IF    ${hasBody}
        ${bodyJson}=    Evaluate    json.dumps(${body})    json
    ELSE
        ${bodyJson}=    Set Variable    {}
    END

    ${response}=    POST    ${url}    data=${bodyJson}    headers=${headers}    expected_status=any
    ${result}=      Parse HTTP Response    ${response}

    # ✅ Check for error flag instead of failing
    ${hasError}=    Run Keyword And Return Status
    ...    Dictionary Should Contain Key    ${result}    _error

    IF    ${hasError}
        ${errorMsg}=    Get From Dictionary    ${result}    _errorMessage
        Fail    ${errorMsg}
    ELSE
        Log To Console    ✓ Success (${response.status_code})
    END

    RETURN    ${result}

Execute PATCH Request
    [Arguments]    ${url}    ${body}    ${headers}

    ${hasBody}=    Run Keyword And Return Status    Should Not Be Empty    ${body}

    IF    ${hasBody}
        ${bodyJson}=    Evaluate    json.dumps(${body})    json
    ELSE
        ${bodyJson}=    Set Variable    {}
    END

    ${response}=    PATCH    ${url}    data=${bodyJson}    headers=${headers}    expected_status=any
    ${result}=      Parse HTTP Response    ${response}

    # ✅ Check for error flag instead of failing
    ${hasError}=    Run Keyword And Return Status
    ...    Dictionary Should Contain Key    ${result}    _error

    IF    ${hasError}
        ${errorMsg}=    Get From Dictionary    ${result}    _errorMessage
        Fail    ${errorMsg}
    ELSE
        # PATCH may return empty body on success (204 No Content)
        ${hasContent}=    Run Keyword And Return Status    Should Not Be Empty    ${response.text}
        IF    not ${hasContent}
            ${result}=    Create Dictionary    success=${True}    status=${response.status_code}
        END
        Log To Console    ✓ Success (${response.status_code})
    END

    RETURN    ${result}

Execute DELETE Request
    [Arguments]    ${url}    ${headers}

    ${response}=    DELETE    ${url}    headers=${headers}    expected_status=any
    ${result}=      Parse HTTP Response    ${response}

    # ✅ Check for error flag instead of failing
    ${hasError}=    Run Keyword And Return Status
    ...    Dictionary Should Contain Key    ${result}    _error

    IF    ${hasError}
        ${errorMsg}=    Get From Dictionary    ${result}    _errorMessage
        Fail    ${errorMsg}
    ELSE
        # DELETE may return empty body on success (204 No Content)
        ${hasContent}=    Run Keyword And Return Status    Should Not Be Empty    ${response.text}
        IF    not ${hasContent}
            ${result}=    Create Dictionary    success=${True}    status=${response.status_code}
        END
        Log To Console    ✓ Success (${response.status_code})
    END

    RETURN    ${result}

Parse HTTP Response
    [Documentation]    Parses HTTP response and handles errors gracefully
    [Arguments]    ${response}

    ${statusCode}=    Set Variable    ${response.status_code}

    # Try to parse JSON response
    TRY
        ${jsonResponse}=    Set Variable    ${response.json()}
    EXCEPT
        ${jsonResponse}=    Create Dictionary
        ...    statusCode=${statusCode}
        ...    body=${response.text}
    END

    # ✅ Handle both dict and list responses
    ${isDict}=    Evaluate    isinstance($jsonResponse, dict)
    ${isList}=    Evaluate    isinstance($jsonResponse, list)

    # If response is a list (common for Salesforce errors), wrap it
    IF    ${isList}
        ${originalResponse}=    Set Variable    ${jsonResponse}
        ${jsonResponse}=    Create Dictionary
        ...    statusCode=${statusCode}
        ...    errors=${originalResponse}
    ELSE IF    ${isDict}
        # Add status code to existing dict
        Set To Dictionary    ${jsonResponse}    statusCode    ${statusCode}
    ELSE
        # Fallback for other types (string, number, etc.)
        ${jsonResponse}=    Create Dictionary
        ...    statusCode=${statusCode}
        ...    body=${jsonResponse}
    END

    # Add error flag for failed requests
    IF    ${statusCode} >= 400
        ${errorMsg}=    Set Variable    HTTP ${statusCode}: ${response.text}
        Set To Dictionary    ${jsonResponse}    _error=${True}    _errorMessage=${errorMsg}
        Log To Console    ❌ HTTP Error ${statusCode}: ${response.text}
    END

    RETURN    ${jsonResponse}

#══════════════════════════════════════════════════════════════════════════════
# VARIABLE INTERPOLATION
#══════════════════════════════════════════════════════════════════════════════
#══════════════════════════════════════════════════════════════════════════════
# DEPENDENCY CHECKING
#══════════════════════════════════════════════════════════════════════════════
Check Dependencies Met
    [Documentation]    Checks if all dependencies have completed successfully.
    ...                Optional dependencies (marked "optional": true) are skipped
    ...                gracefully and do not block dependent operations.
    [Arguments]    ${dependsOn}    ${results}    ${errors}    ${allOperations}

    # Normalise dependsOn — always work with a list
    ${isList}=    Evaluate    isinstance($dependsOn, list)
    IF    ${isList}
        ${depList}=    Set Variable    ${dependsOn}
    ELSE
        ${depList}=    Create List    ${dependsOn}
    END

    FOR    ${dep}    IN    @{depList}

        # Check result and error state for this dependency
        ${hasResult}=    Run Keyword And Return Status    Dictionary Should Contain Key    ${results}    ${dep}
        ${hasError}=    Run Keyword And Return Status    Dictionary Should Contain Key    ${errors}    ${dep}

        # Determine whether this dependency is marked as optional
        ${isOptional}=    Set Variable    ${False}
        FOR    ${operation}    IN    @{allOperations}
            ${opId}=    Get From Dictionary    ${operation}    id
            IF    '${opId}' == '${dep}'
                ${opHasOptional}=    Run Keyword And Return Status    Dictionary Should Contain Key    ${operation}    optional
                IF    ${opHasOptional}
                    ${isOptional}=    Get From Dictionary    ${operation}    optional
                END
            END
        END

        # Optional failed dependency — log and skip, do not block
        IF    ${hasError} and ${isOptional}
            Log To Console    ⚠ Optional dependency '${dep}' failed — continuing anyway
            CONTINUE
        END

        # Required dependency missing or failed — block execution
        IF    not ${hasResult} or ${hasError}
            RETURN    ${False}
        END

    END
    RETURN    ${True}

#══════════════════════════════════════════════════════════════════════════════
# APEX EXECUTE ANONYMOUS
#══════════════════════════════════════════════════════════════════════════════
Execute Apex Operation
    [Documentation]    Execute anonymous Apex code via Tooling API
    [Arguments]    ${op}    ${results}

    ${apexCode}=    Get From Dictionary    ${op}    code
    ${apexCode}=    Resolve Variables In String    ${apexCode}    ${results}

    ${headers}=    Create Dictionary
    ...    Authorization=Bearer ${SUITE_TOKEN}
    ...    Content-Type=application/json

    ${encodedApex}=    Evaluate    __import__('urllib').parse.quote($apexCode)
    ${endpoint}=       Set Variable    /services/data/v65.0/tooling/executeAnonymous/?anonymousBody=${encodedApex}
    ${fullUrl}=        Set Variable    ${SUITE_INSTANCE_URL}${endpoint}

    Log To Console    ⚡ Executing Apex: ${apexCode[:50]}...

    TRY
        ${response}=    RequestsLibrary.GET    url=${fullUrl}    headers=${headers}    expected_status=any
        ${result}=      Parse HTTP Response    ${response}

        ${hasError}=    Run Keyword And Return Status
        ...    Dictionary Should Contain Key    ${result}    _error

        IF    ${hasError}
            ${errorMsg}=    Get From Dictionary    ${result}    _errorMessage
            Fail    ${errorMsg}
        END

        ${compiled}=    Get From Dictionary    ${result}    compiled
        ${success}=     Get From Dictionary    ${result}    success

        IF    not ${compiled}
            ${compileError}=    Get From Dictionary    ${result}    compileProblem    default=Unknown compilation error
            Fail    Apex compilation failed: ${compileError}
        END

        IF    not ${success}
            ${exceptionMsg}=    Get From Dictionary    ${result}    exceptionMessage    default=Unknown runtime error
            ${exceptionStack}=  Get From Dictionary    ${result}    exceptionStackTrace    default=${EMPTY}
            Fail    Apex execution failed: ${exceptionMsg}\n${exceptionStack}
        END

        Log To Console    ✅ Apex executed successfully

    EXCEPT    AS    ${error}
        ${result}=    Create Dictionary
        ...    _error=${True}
        ...    _errorMessage=${error}
        Log To Console    ❌ Apex execution failed: ${error}
        Fail    ${error}
    END

    RETURN    ${result}

#══════════════════════════════════════════════════════════════════════════════
# BULK API 2.0 OPERATIONS
#══════════════════════════════════════════════════════════════════════════════
Execute Bulk Operation
    [Documentation]    Execute Bulk API 2.0 operations (insert, update, delete, upsert)
    [Arguments]    ${op}    ${results}

    ${action}=            Get From Dictionary    ${op}    action
    ${sobject}=           Get From Dictionary    ${op}    sobject
    ${data}=              Get From Dictionary    ${op}    data               default=${EMPTY}
    ${externalIdField}=   Get From Dictionary    ${op}    externalIdField    default=${EMPTY}
    ${waitForCompletion}= Get From Dictionary    ${op}    waitForCompletion  default=${True}
    ${pollInterval}=      Get From Dictionary    ${op}    pollInterval       default=5
    ${maxWaitTime}=       Get From Dictionary    ${op}    maxWaitTime        default=300

    ${headers}=    Create Dictionary
    ...    Authorization=Bearer ${SUITE_TOKEN}
    ...    Content-Type=application/json

    Log To Console    📦 Bulk ${action} on ${sobject}

    TRY
        # Step 1: Create Bulk Job
        ${jobPayload}=    Create Dictionary
        ...    object=${sobject}
        ...    operation=${action}

        IF    '${externalIdField}' != '${EMPTY}'
            Set To Dictionary    ${jobPayload}    externalIdFieldName    ${externalIdField}
        END

        ${jobJson}=        Evaluate    json.dumps($jobPayload)    json
        ${createJobUrl}=   Set Variable    ${SUITE_INSTANCE_URL}/services/data/v65.0/jobs/ingest

        ${createResponse}=    RequestsLibrary.POST    url=${createJobUrl}    data=${jobJson}    headers=${headers}    expected_status=any
        ${jobResult}=         Parse HTTP Response    ${createResponse}

        ${hasError}=    Run Keyword And Return Status
        ...    Dictionary Should Contain Key    ${jobResult}    _error

        IF    ${hasError}
            ${errorMsg}=    Get From Dictionary    ${jobResult}    _errorMessage
            Fail    Failed to create bulk job: ${errorMsg}
        END

        ${jobId}=    Get From Dictionary    ${jobResult}    id
        Log To Console    ✓ Created job: ${jobId}

        # Step 2: Upload Data (if provided)
        ${hasData}=    Run Keyword And Return Status    Should Not Be Empty    ${data}

        IF    ${hasData}
            ${csvData}=      Convert Data To CSV    ${data}
            ${uploadUrl}=    Set Variable    ${SUITE_INSTANCE_URL}/services/data/v65.0/jobs/ingest/${jobId}/batches
            ${uploadHeaders}=    Create Dictionary
            ...    Authorization=Bearer ${SUITE_TOKEN}
            ...    Content-Type=text/csv

            ${uploadResponse}=    RequestsLibrary.PUT    url=${uploadUrl}    data=${csvData}    headers=${uploadHeaders}    expected_status=any

            IF    ${uploadResponse.status_code} != 201
                Fail    Failed to upload data: ${uploadResponse.text}
            END

            Log To Console    ✓ Uploaded data
        END

        # Step 3: Close Job
        ${closePayload}=    Create Dictionary    state=UploadComplete
        ${closeJson}=       Evaluate    json.dumps($closePayload)    json
        ${closeUrl}=        Set Variable    ${SUITE_INSTANCE_URL}/services/data/v65.0/jobs/ingest/${jobId}

        ${closeResponse}=    RequestsLibrary.PATCH    url=${closeUrl}    data=${closeJson}    headers=${headers}    expected_status=any

        IF    ${closeResponse.status_code} != 200
            Fail    Failed to close job: ${closeResponse.text}
        END

        Log To Console    ✓ Job closed, processing...

        # Step 4: Wait for completion (if requested)
        IF    ${waitForCompletion}
            ${finalStatus}=    Wait For Bulk Job Completion    ${jobId}    ${pollInterval}    ${maxWaitTime}
            RETURN    ${finalStatus}
        ELSE
            ${result}=    Create Dictionary    jobId=${jobId}    state=InProgress
            RETURN    ${result}
        END

    EXCEPT    AS    ${error}
        ${result}=    Create Dictionary
        ...    _error=${True}
        ...    _errorMessage=${error}
        Log To Console    ❌ Bulk operation failed: ${error}
        Fail    ${error}
    END

Wait For Bulk Job Completion
    [Documentation]    Polls bulk job status until completion or timeout
    [Arguments]    ${jobId}    ${pollInterval}    ${maxWaitTime}

    ${headers}=    Create Dictionary
    ...    Authorization=Bearer ${SUITE_TOKEN}
    ...    Content-Type=application/json

    ${statusUrl}=    Set Variable    ${SUITE_INSTANCE_URL}/services/data/v65.0/jobs/ingest/${jobId}
    ${startTime}=    Get Time    epoch

    WHILE    True
        ${response}=    RequestsLibrary.GET    url=${statusUrl}    headers=${headers}    expected_status=any
        ${status}=      Parse HTTP Response    ${response}

        ${state}=             Get From Dictionary    ${status}    state
        ${recordsProcessed}=  Get From Dictionary    ${status}    numberRecordsProcessed    default=0
        ${recordsFailed}=     Get From Dictionary    ${status}    numberRecordsFailed        default=0

        Log To Console    ⏳ Job ${state}: ${recordsProcessed} processed, ${recordsFailed} failed

        ${isComplete}=    Evaluate    '${state}' in ['JobComplete', 'Failed', 'Aborted']

        IF    ${isComplete}
            IF    '${state}' == 'JobComplete'
                Log To Console    ✅ Bulk job completed successfully
            ELSE
                Log To Console    ❌ Bulk job ${state}
            END
            RETURN    ${status}
        END

        ${currentTime}=    Get Time    epoch
        ${elapsed}=        Evaluate    ${currentTime} - ${startTime}

        IF    ${elapsed} > ${maxWaitTime}
            Fail    Bulk job timeout after ${maxWaitTime} seconds
        END

        Sleep    ${pollInterval}s
    END

#══════════════════════════════════════════════════════════════════════════════
# BATCH APEX STATUS MONITORING
#══════════════════════════════════════════════════════════════════════════════
Execute Batch Status Operation
    [Documentation]    Check status of Batch Apex (707) or Bulk API 2.0 (750) jobs
    [Arguments]    ${op}    ${results}

    ${jobId}=    Get From Dictionary    ${op}    jobId    default=${EMPTY}
    ${jobId}=    Resolve Variables In String    ${jobId}    ${results}

    Log To Console    🔍 Checking job status: ${jobId}

    # Determine job type by ID prefix
    ${prefix}=    Get Substring    ${jobId}    0    3

    IF    '${prefix}' == '750'
        # Bulk API 2.0 job - use REST endpoint
        ${result}=    Get Bulk API Job Status    ${jobId}
    ELSE IF    '${prefix}' == '707'
        # Batch Apex job - use Tooling API query
        ${result}=    Get Batch Apex Job Status    ${jobId}
    ELSE IF    '${prefix}' == '751'
        Fail    Bulk API 1.0 (751 prefix) is not supported. Use Bulk API 2.0 instead.
    ELSE
        Fail    Unknown job ID prefix: ${prefix}. Expected 707 (Batch Apex) or 750 (Bulk API 2.0)
    END

    RETURN    ${result}

Get Bulk API Job Status
    [Documentation]    Get status of Bulk API 2.0 job (750 prefix)
    [Arguments]    ${jobId}

    ${headers}=    Create Dictionary
    ...    Authorization=Bearer ${SUITE_TOKEN}
    ...    Content-Type=application/json

    ${statusUrl}=    Set Variable    ${SUITE_INSTANCE_URL}/services/data/v65.0/jobs/ingest/${jobId}

    TRY
        ${response}=    RequestsLibrary.GET    url=${statusUrl}    headers=${headers}    expected_status=any
        ${status}=      Parse HTTP Response    ${response}

        ${hasError}=    Run Keyword And Return Status
        ...    Dictionary Should Contain Key    ${status}    _error

        IF    ${hasError}
            ${errorMsg}=    Get From Dictionary    ${status}    _errorMessage
            Fail    Failed to get Bulk API job status: ${errorMsg}
        END

        # Log status
        ${state}=            Get From Dictionary    ${status}    state
        ${recordsProcessed}= Get From Dictionary    ${status}    numberRecordsProcessed    default=0
        ${recordsFailed}=    Get From Dictionary    ${status}    numberRecordsFailed        default=0

        Log To Console    📊 Bulk API Job ${jobId}: ${state} (${recordsProcessed} processed, ${recordsFailed} failed)

    EXCEPT    AS    ${error}
        ${result}=    Create Dictionary
        ...    _error=${True}
        ...    _errorMessage=${error}
        Log To Console    ❌ Failed to get Bulk API job status: ${error}
        Fail    ${error}
    END

    RETURN    ${status}

Get Batch Apex Job Status
    [Documentation]    Get status of Batch Apex job (707 prefix)
    [Arguments]    ${jobId}

    ${query}=    Set Variable    SELECT Id, Status, JobType, JobItemsProcessed, TotalJobItems, NumberOfErrors, CreatedDate, CompletedDate, ExtendedStatus FROM AsyncApexJob WHERE Id = '${jobId}'

    ${headers}=    Create Dictionary
    ...    Authorization=Bearer ${SUITE_TOKEN}
    ...    Content-Type=application/json

    ${encodedQuery}=    Evaluate    __import__('urllib').parse.quote($query)
    ${endpoint}=        Set Variable    /services/data/v65.0/tooling/query/?q=${encodedQuery}
    ${fullUrl}=         Set Variable    ${SUITE_INSTANCE_URL}${endpoint}

    TRY
        ${response}=    RequestsLibrary.GET    url=${fullUrl}    headers=${headers}    expected_status=any
        ${result}=      Parse HTTP Response    ${response}

        ${hasError}=    Run Keyword And Return Status
        ...    Dictionary Should Contain Key    ${result}    _error

        IF    ${hasError}
            ${errorMsg}=    Get From Dictionary    ${result}    _errorMessage
            Fail    ${errorMsg}
        END

        ${totalSize}=    Get From Dictionary    ${result}    totalSize

        IF    ${totalSize} == 0
            Fail    Batch Apex job not found: ${jobId}
        END

        ${records}=    Get From Dictionary    ${result}    records
        ${jobInfo}=    Get From List    ${records}    0

        # Log status
        ${status}=     Get From Dictionary    ${jobInfo}    Status
        ${jobType}=    Get From Dictionary    ${jobInfo}    JobType              default=Unknown
        ${processed}=  Get From Dictionary    ${jobInfo}    JobItemsProcessed
        ${total}=      Get From Dictionary    ${jobInfo}    TotalJobItems
        ${errors}=     Get From Dictionary    ${jobInfo}    NumberOfErrors

        Log To Console    📊 Batch Apex Job ${jobId}: ${status} (${jobType}, ${processed}/${total} items, ${errors} errors)

    EXCEPT    AS    ${error}
        ${result}=    Create Dictionary
        ...    _error=${True}
        ...    _errorMessage=${error}
        Log To Console    ❌ Failed to get Batch Apex job status: ${error}
        Fail    ${error}
    END

    RETURN    ${jobInfo}

#══════════════════════════════════════════════════════════════════════════════
# BULK DATA HELPERS
#══════════════════════════════════════════════════════════════════════════════
Execute Foreach Operation
    [Documentation]    Iterates over a resolved source collection and executes a
    ...                templated child REST operation for each item.
    ...                Config keys: items (path), itemVar, keyTemplate, operation.
    ...                Stores each child result under the resolved keyTemplate key.
    [Arguments]    ${op}    ${results}

    # ── Read the FOREACH config keys (matching our JSON contract) ────────────
    ${itemsPath}=     Get From Dictionary    ${op}    items
    ${itemVar}=       Get From Dictionary    ${op}    itemVar
    ${keyTemplate}=   Get From Dictionary    ${op}    keyTemplate
    ${template}=      Get From Dictionary    ${op}    operation

    # ── Strip outer braces from path e.g. "{activeRecordTypes.records}" ──────
    ${cleanPath}=     Evaluate    '${itemsPath}'.strip('{}')

    # ── Navigate the path manually using existing keywords ───────────────────
    # Split "activeRecordTypes.records" into ["activeRecordTypes", "records"]
    ${pathParts}=     Evaluate    '${cleanPath}'.split('.')
    ${collection}=    Set Variable    ${results}
    FOR    ${part}    IN    @{pathParts}
        ${collection}=    Get From Dictionary    ${collection}    ${part}
    END

    ${foreachResults}=    Create Dictionary

    FOR    ${item}    IN    @{collection}
        # ── Merge iterator variable into a local results copy ─────────────────
        ${iterResults}=    Copy Dictionary    ${results}
        Set To Dictionary    ${iterResults}    ${itemVar}    ${item}

        # ── Resolve the dynamic key and endpoint ─────────────────────────────
        ${resolvedKey}=       Resolve Variables In String    ${keyTemplate}    ${iterResults}
        ${resolvedEndpoint}=  Resolve Variables In String    ${template}[endpoint]    ${iterResults}

        # ── Build the resolved child operation dict ───────────────────────────
        ${childOp}=    Copy Dictionary    ${template}
        Set To Dictionary    ${childOp}    id          ${resolvedKey}
        Set To Dictionary    ${childOp}    endpoint    ${resolvedEndpoint}

        # ── Execute and store under the resolved dynamic key ──────────────────
        ${childResult}=    Execute REST Operation    ${childOp}    ${iterResults}
        Set To Dictionary    ${foreachResults}    ${resolvedKey}    ${childResult}

        Log To Console    ✅ FOREACH: ${resolvedKey} completed
    END

    RETURN    ${foreachResults}
Convert Data To CSV
    [Documentation]    Convert list of dictionaries to CSV format
    [Arguments]    ${data}

    # Get headers from first record
    ${firstRecord}=    Get From List    ${data}    0
    ${headers}=        Get Dictionary Keys    ${firstRecord}

    # Create header row
    ${headerRow}=    Evaluate    ','.join($headers)
    ${csvRows}=      Create List    ${headerRow}

    # Create data rows
    FOR    ${record}    IN    @{data}
        ${values}=    Create List
        FOR    ${header}    IN    @{headers}
            ${value}=        Get From Dictionary    ${record}    ${header}    default=${EMPTY}
            # Escape quotes and wrap in quotes
            ${escapedValue}=    Evaluate    str($value).replace('"', '""')
            ${quotedValue}=     Set Variable    "${escapedValue}"
            Append To List    ${values}    ${quotedValue}
        END
        ${row}=    Evaluate    ','.join($values)
        Append To List    ${csvRows}    ${row}
    END

    # Join all rows with actual newline using Python's join
    ${csv}=    Evaluate    "\\n".join($csvRows)

    RETURN    ${csv}
