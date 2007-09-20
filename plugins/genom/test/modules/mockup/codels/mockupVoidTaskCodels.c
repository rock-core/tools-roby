/**
 ** mockupVoidTaskCodels.c
 **
 ** Codels called by execution task mockupVoidTask
 **
 ** Author: 
 ** Date: 
 **
 **/

#ifdef VXWORKS
# include <vxWorks.h>
#else
# include <portLib.h>
#endif
#include "server/mockupHeader.h"


/*------------------------------------------------------------------------
 *
 * mockupVoidTaskInit  --  Initialization codel (fIDS, ...)
 *
 * Description: 
 * 
 * Returns:    OK or ERROR
 */

STATUS
mockupVoidTaskInit(int *report)
{
  /* ... add your code here ... */
  return OK;
}

/*------------------------------------------------------------------------
 * Start
 *
 * Description: 
 *
 * Reports:      OK
 */

/* do_count  -  codel EXEC of Start
   Returns:  EXEC END ETHER FAIL ZOMBIE */
ACTIVITY_EVENT
do_count(int *report)
{
  /* ... add your code here ... */
  return EXEC;
}

ACTIVITY_EVENT
return_failure(int *error, int *report)
{
    if (*error == 1)
	*report = S_mockup_FIRST_ERROR;
    else if (*error == 2)
	*report = S_mockup_SECOND_ERROR;
    return ETHER;
}

