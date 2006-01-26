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


