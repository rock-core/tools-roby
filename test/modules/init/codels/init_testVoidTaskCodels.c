/**
 ** init_testVoidTaskCodels.c
 **
 ** Codels called by execution task init_testVoidTask
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
#include "server/init_testHeader.h"


/*------------------------------------------------------------------------
 *
 * initVoidTaskInit  --  Initialization codel (fIDS, ...)
 *
 * Description: 
 * 
 * Returns:    OK or ERROR
 */

STATUS
initVoidTaskInit(int *report)
{
  /* ... add your code here ... */
  return OK;
}

/*------------------------------------------------------------------------
 * Init
 *
 * Description: 
 *
 * Reports:      OK
 */

/* InitPeriod  -  codel EXEC of Init
   Returns:  EXEC END ETHER FAIL ZOMBIE */
ACTIVITY_EVENT
InitPeriod(int *update_period, int *report)
{
  return ETHER;
}


