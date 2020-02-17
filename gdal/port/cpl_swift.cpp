/**********************************************************************
 * Project:  CPL - Common Portability Library
 * Purpose:  OpenStack Swift Object Storage routines
 * Author:   Even Rouault <even.rouault at spatialys.com>
 *
 **********************************************************************
 * Copyright (c) 2018, Even Rouault <even.rouault at spatialys.com>
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included
 * in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINSwift IN THE SOFTWARE.
 ****************************************************************************/

#include "cpl_swift.h"
#include "cpl_vsi_error.h"
#include "cpl_http.h"
#include "cpl_multiproc.h"
#include "cpl_json.h"

// HOWTO setup a Docker-based SWIFT server:
// https://github.com/MorrisJobke/docker-swift-onlyone


//! @cond Doxygen_Suppress

CPL_CVSID("$Id$")

#ifdef HAVE_CURL

static CPLMutex *g_hMutex = nullptr;
static CPLString g_osLastAuthURL;
static CPLString g_osLastUser;
static CPLString g_osLastKey;
static CPLString g_osLastStorageURL;
static CPLString g_osLastAuthToken;

/************************************************************************/
/*                          GetSwiftHeaders()                           */
/************************************************************************/

static
struct curl_slist* GetSwiftHeaders( const CPLString& osAuthToken )
{
    struct curl_slist *headers=nullptr;
    headers = curl_slist_append(
        headers, "Accept: application/json");
    headers = curl_slist_append(
        headers, CPLSPrintf("x-auth-token: %s", osAuthToken.c_str()));
    return headers;
}

/************************************************************************/
/*                     VSISwiftHandleHelper()                           */
/************************************************************************/
VSISwiftHandleHelper::VSISwiftHandleHelper(const CPLString& osStorageURL,
                                           const CPLString& osAuthToken,
                                           const CPLString& osBucket,
                                           const CPLString& osObjectKey) :
    m_osURL(BuildURL(osStorageURL, osBucket, osObjectKey)),
    m_osStorageURL(osStorageURL),
    m_osAuthToken(osAuthToken),
    m_osBucket(osBucket),
    m_osObjectKey(osObjectKey)
{
}

/************************************************************************/
/*                      ~VSISwiftHandleHelper()                         */
/************************************************************************/

VSISwiftHandleHelper::~VSISwiftHandleHelper()
{
}

/************************************************************************/
/*                           AuthV1()                         */
/************************************************************************/

bool VSISwiftHandleHelper::AuthV1(CPLString& osStorageURL,
                                  CPLString& osAuthToken)
{
    CPLString osAuthURL = CPLGetConfigOption("SWIFT_AUTH_V1_URL", "");
    CPLString osUser = CPLGetConfigOption("SWIFT_USER", "");
    CPLString osKey = CPLGetConfigOption("SWIFT_KEY", "");
    char** papszHeaders = CSLSetNameValue(nullptr, "HEADERS",
        CPLSPrintf("X-Auth-User: %s\r\n"
                   "X-Auth-Key: %s",
                   osUser.c_str(),
                   osKey.c_str()));
    CPLHTTPResult* psResult = CPLHTTPFetch(osAuthURL, papszHeaders);
    CSLDestroy(papszHeaders);
    if( psResult == nullptr )
        return false;
    osStorageURL = CSLFetchNameValueDef(psResult->papszHeaders,
                                        "X-Storage-Url", "");
    osAuthToken = CSLFetchNameValueDef(psResult->papszHeaders,
                                       "X-Auth-Token", "");
    CPLString osErrorMsg = psResult->pabyData ?
                reinterpret_cast<const char*>(psResult->pabyData) : "";
    CPLHTTPDestroyResult(psResult);
    if( osStorageURL.empty() || osAuthToken.empty() )
    {
        CPLDebug("SWIFT", "Authentication failed: %s", osErrorMsg.c_str());
        VSIError(VSIE_AWSInvalidCredentials,
                 "Authentication failed: %s", osErrorMsg.c_str());
        return false;
    }

    // Cache credentials
    {
        CPLMutexHolder oHolder( &g_hMutex );
        g_osLastAuthURL = osAuthURL;
        g_osLastUser = osUser;
        g_osLastKey = osKey;
        g_osLastStorageURL = osStorageURL;
        g_osLastAuthToken = osAuthToken;
    }

    return true;
}

/************************************************************************/
/*                           AuthV3()                         */
/************************************************************************/
CPLJSONObject VSISwiftHandleHelper::CreateAuthV3RequestObject()
{
    CPLString osUser = CPLGetConfigOption("SWIFT_USER", "");
    CPLString osKey = CPLGetConfigOption("SWIFT_KEY", "");
    CPLString osProjectDomainName = CPLGetConfigOption("SWIFT_PROJECT_DOMAIN_NAME", "");
    CPLString osProjectName = CPLGetConfigOption("SWIFT_PROJECT_NAME", "");
    CPLString osUserDomainName = CPLGetConfigOption("SWIFT_USER_DOMAIN_NAME", "");

    CPLJSONObject userDomain;
    userDomain.Add("name", osUserDomainName);

    CPLJSONObject projectDomain;
    projectDomain.Add("name", osProjectDomainName);

    CPLJSONObject password;
    password.Add("name", osUser);
    password.Add("password", osKey);
    password.Add("domain", userDomain);

    CPLJSONArray methods;
    methods.Add("password");

    CPLJSONObject identity;
    identity.Add("methods", methods);
    identity.Add("password", password);

    CPLJSONObject project;
    project.Add("name", osProjectName);
    project.Add("domain", projectDomain);

    CPLJSONObject scope;
    scope.Add("project", project);

    CPLJSONObject auth;
    auth.Add("identity", identity);
    auth.Add("scope", scope);

    CPLJSONObject obj;
    obj.Add("auth", auth);
    return obj;
}

bool VSISwiftHandleHelper::GetAuthV3StorageURL(const CPLHTTPResult *psResult,
                                               CPLString& storageURL)
{
    if( psResult->pabyData == nullptr )
        return false;

    CPLJSONDocument resultJson;
    resultJson.LoadMemory(psResult->pabyData);
    CPLJSONObject result(resultJson.GetRoot());

    CPLJSONObject token(result.GetObj("token"));
    if( ! token.IsValid() )
        return false;

    CPLJSONArray catalog(token.GetArray("catalog"));
    if( ! catalog.IsValid() )
        return false;

    CPLJSONArray endpoints;
    for(int i = 0; i < catalog.Size(); ++i)
    {
        CPLJSONObject item(catalog[i]);
        if( item.GetString("name") == "swift" )
        {
            endpoints = item.GetArray("endpoints");
            break;
        }
    }

    if( endpoints.Size() == 0 )
        return false;

    CPLString osRegionName = CPLGetConfigOption("SWIFT_REGION_NAME", "");
    if( osRegionName.empty() )
    {
        CPLJSONObject endpoint(endpoints[0]);
        storageURL = endpoint.GetString("url");
        return true;
    }

    for(int i = 0; i < endpoints.Size(); ++i)
    {
        CPLJSONObject endpoint(endpoints[0]);
        if( endpoint.GetString("name") == osRegionName )
        {
            storageURL = endpoint.GetString("url");
            return true;
        }
    }

    return false;
}

bool VSISwiftHandleHelper::AuthV3(CPLString& osStorageURL,
                                  CPLString& osAuthToken)
{
    CPLString osUser = CPLGetConfigOption("SWIFT_USER", "");
    CPLString osKey = CPLGetConfigOption("SWIFT_KEY", "");
    CPLJSONObject postObject(CreateAuthV3RequestObject());
    std::string post = postObject.Format(CPLJSONObject::PrettyFormat::Plain);

    CPLString osAuthURL = CPLGetConfigOption("SWIFT_AUTH_V3_URL", "");
    char** papszOptions = CSLSetNameValue(nullptr, "POSTFIELDS", post.data());
    CPLHTTPResult *psResult = CPLHTTPFetchEx( osAuthURL.c_str(), papszOptions,
                                              nullptr, nullptr,
                                              nullptr, nullptr );
    CSLDestroy( papszOptions );

    if( psResult == nullptr )
        return false;

    osAuthToken = CSLFetchNameValueDef(psResult->papszHeaders,
                                       "X-Subject-Token", "");

    if( ! GetAuthV3StorageURL(psResult, osStorageURL) )
        return false;

    if( osStorageURL.empty() || osAuthToken.empty() )
    {
        CPLString osErrorMsg = reinterpret_cast<const char*>(psResult->pabyData);
        CPLDebug("SWIFT", "Authentication failed: %s", osErrorMsg.c_str());
        VSIError(VSIE_AWSInvalidCredentials,
                 "Authentication failed: %s", osErrorMsg.c_str());
        CPLHTTPDestroyResult(psResult);
        return false;
    }

    CPLHTTPDestroyResult(psResult);

    // Cache credentials
    {
        CPLMutexHolder oHolder( &g_hMutex );
        g_osLastAuthURL = osAuthURL;
        g_osLastUser = osUser;
        g_osLastKey = osKey;
        g_osLastStorageURL = osStorageURL;
        g_osLastAuthToken = osAuthToken;
    }

    return true;
}

/************************************************************************/
/*                           Authenticate()                             */
/************************************************************************/

bool VSISwiftHandleHelper::Authenticate()
{
    CPLString osAuthV1URL = CPLGetConfigOption("SWIFT_AUTH_V1_URL", "");
    if( !osAuthV1URL.empty() )
    {
        return AuthV1(m_osStorageURL, m_osAuthToken);
    }

    CPLString osAuthV3URL = CPLGetConfigOption("SWIFT_AUTH_V3_URL", "");
    if( !osAuthV3URL.empty() )
    {
        return AuthV3(m_osStorageURL, m_osAuthToken);
    }

    return false;
}

/************************************************************************/
/*                           Authenticate()                             */
/************************************************************************/

bool VSISwiftHandleHelper::CheckCredentialsV1()
{
    CPLString osAuthURL = CPLGetConfigOption("SWIFT_AUTH_V1_URL", "");
    if( osAuthURL.empty() )
        return false;

    CPLString osUser = CPLGetConfigOption("SWIFT_USER", "");
    CPLString osKey = CPLGetConfigOption("SWIFT_KEY", "");
    if( osAuthURL.empty() || osUser.empty() || osKey.empty() )
    {
        const char* pszMsg = "Missing SWIFT_STORAGE_URL+SWIFT_AUTH_TOKEN or "
                             "SWIFT_AUTH_V1_URL+SWIFT_USER+SWIFT_KEY "
                             "configuration options";
        CPLDebug("SWIFT", "%s", pszMsg);
        VSIError(VSIE_AWSInvalidCredentials, "%s", pszMsg);
        return false;
    }
    return true;
}

bool VSISwiftHandleHelper::CheckCredentialsV3()
{
    CPLString osAuthURL = CPLGetConfigOption("SWIFT_AUTH_V3_URL", "");
    if( osAuthURL.empty() )
        return false;

    CPLString osUser = CPLGetConfigOption("SWIFT_USER", "");
    CPLString osKey = CPLGetConfigOption("SWIFT_KEY", "");
    if( osAuthURL.empty() || osUser.empty() || osKey.empty() )
    {
        const char* pszMsg = "Missing SWIFT_STORAGE_URL+SWIFT_AUTH_TOKEN or "
                             "SWIFT_AUTH_V3_URL+SWIFT_USER+SWIFT_KEY "
                             "configuration options";
        CPLDebug("SWIFT", "%s", pszMsg);
        VSIError(VSIE_AWSInvalidCredentials, "%s", pszMsg);
        return false;
    }
    return true;
}

// Re-use cached credentials if available
bool VSISwiftHandleHelper::GetCachedAuthV1(CPLString& osStorageURL,
                                           CPLString& osAuthToken)
{
    CPLString osAuthURL = CPLGetConfigOption("SWIFT_AUTH_V1_URL", "");
    CPLString osUser = CPLGetConfigOption("SWIFT_USER", "");
    CPLString osKey = CPLGetConfigOption("SWIFT_KEY", "");

    CPLMutexHolder oHolder( &g_hMutex );
    // coverity[tainted_data]
    if( osAuthURL == g_osLastAuthURL &&
        osUser == g_osLastUser &&
        osKey == g_osLastKey )
    {
        osStorageURL = g_osLastStorageURL;
        osAuthToken = g_osLastAuthToken;
        return true;
    }
    return false;
}

// Re-use cached credentials if available
bool VSISwiftHandleHelper::GetCachedAuthV3(CPLString& osStorageURL,
                                           CPLString& osAuthToken)
{
    CPLString osAuthURL = CPLGetConfigOption("SWIFT_AUTH_V3_URL", "");
    CPLString osUser = CPLGetConfigOption("SWIFT_USER", "");
    CPLString osKey = CPLGetConfigOption("SWIFT_KEY", "");

    CPLMutexHolder oHolder( &g_hMutex );
    // coverity[tainted_data]
    if( osAuthURL == g_osLastAuthURL &&
        osUser == g_osLastUser &&
        osKey == g_osLastKey )
    {
        osStorageURL = g_osLastStorageURL;
        osAuthToken = g_osLastAuthToken;
        return true;
    }
    return false;
}

/************************************************************************/
/*                        GetConfiguration()                            */
/************************************************************************/

bool VSISwiftHandleHelper::GetConfiguration(CPLString& osStorageURL,
                                            CPLString& osAuthToken)
{
    osStorageURL = CPLGetConfigOption("SWIFT_STORAGE_URL", "");
    if( !osStorageURL.empty() )
    {
        osAuthToken = CPLGetConfigOption("SWIFT_AUTH_TOKEN", "");
        if( osAuthToken.empty() )
        {
            const char* pszMsg = "Missing SWIFT_AUTH_TOKEN";
            CPLDebug("SWIFT", "%s", pszMsg);
            VSIError(VSIE_AWSInvalidCredentials, "%s", pszMsg);
            return false;
        }
        return true;
    }

    if ( CheckCredentialsV3() )
    {
        if( GetCachedAuthV3(osStorageURL, osAuthToken) )
            return true;
        if( AuthV3(osStorageURL, osAuthToken) )
            return true;
    }

    if ( CheckCredentialsV1() )
    {
        if( GetCachedAuthV1(osStorageURL, osAuthToken) )
            return true;
        if( AuthV1(osStorageURL, osAuthToken) )
            return true;
    }

    return false;
}


/************************************************************************/
/*                          BuildFromURI()                              */
/************************************************************************/

VSISwiftHandleHelper* VSISwiftHandleHelper::BuildFromURI( const char* pszURI,
                                                    const char* /*pszFSPrefix*/ )
{
    CPLString osStorageURL;
    CPLString osAuthToken;

    if( !GetConfiguration(osStorageURL, osAuthToken) )
    {
        return nullptr;
    }

    // pszURI == bucket/object
    const CPLString osBucketObject( pszURI );
    CPLString osBucket(osBucketObject);
    CPLString osObjectKey;
    size_t nSlashPos = osBucketObject.find('/');
    if( nSlashPos != std::string::npos )
    {
        osBucket = osBucketObject.substr(0, nSlashPos);
        osObjectKey = osBucketObject.substr(nSlashPos+1);
    }

    return new VSISwiftHandleHelper( osStorageURL,
                                     osAuthToken,
                                     osBucket,
                                     osObjectKey );
}

/************************************************************************/
/*                            BuildURL()                                */
/************************************************************************/

CPLString VSISwiftHandleHelper::BuildURL(const CPLString& osStorageURL,
                                         const CPLString& osBucket,
                                         const CPLString& osObjectKey)
{
    CPLString osURL = osStorageURL;
    if( !osBucket.empty() )
        osURL += "/" + CPLAWSURLEncode(osBucket,false);
    if( !osObjectKey.empty() )
        osURL += "/" + CPLAWSURLEncode(osObjectKey,false);
    return osURL;
}


/************************************************************************/
/*                           RebuildURL()                               */
/************************************************************************/

void VSISwiftHandleHelper::RebuildURL()
{
    m_osURL = BuildURL(m_osStorageURL, m_osBucket, m_osObjectKey);
    m_osURL += GetQueryString(false);
}

/************************************************************************/
/*                           GetCurlHeaders()                           */
/************************************************************************/

struct curl_slist *
VSISwiftHandleHelper::GetCurlHeaders( const CPLString&,
                                          const struct curl_slist*,
                                          const void *,
                                          size_t ) const
{
    return GetSwiftHeaders( m_osAuthToken );
}

/************************************************************************/
/*                          CleanMutex()                                */
/************************************************************************/

void VSISwiftHandleHelper::CleanMutex()
{
    if( g_hMutex != nullptr )
        CPLDestroyMutex( g_hMutex );
    g_hMutex = nullptr;
}

/************************************************************************/
/*                          ClearCache()                                */
/************************************************************************/

void VSISwiftHandleHelper::ClearCache()
{
    CPLMutexHolder oHolder( &g_hMutex );
    g_osLastAuthURL.clear();
    g_osLastUser.clear();
    g_osLastKey.clear();
    g_osLastStorageURL.clear();
    g_osLastAuthToken.clear();
}

#endif

//! @endcond
