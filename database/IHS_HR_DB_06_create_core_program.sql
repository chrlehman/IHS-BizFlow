
SET DEFINE OFF;

--=============================================================================
-- Create STORED PROCEDURE for CMS project
-------------------------------------------------------------------------------



--------------------------------------------------------
--  DDL for Procedure SP_ERROR_LOG
--------------------------------------------------------

/**
 * Stores database errors to ERROR_LOG table to help troubleshooting.
 *
 */
CREATE OR REPLACE PROCEDURE SP_ERROR_LOG
IS
	PRAGMA AUTONOMOUS_TRANSACTION;
	V_CODE      PLS_INTEGER := SQLCODE;
	V_MSG       VARCHAR2(32767) := SQLERRM;
BEGIN
	INSERT INTO ERROR_LOG
	(
		ERROR_CD
		, ERROR_MSG
		, BACKTRACE
		, CALLSTACK
		, CRT_DT
		, CRT_USR
	)
	VALUES (
		V_CODE
		, V_MSG
		, SYS.DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
		, SYS.DBMS_UTILITY.FORMAT_CALL_STACK
		, SYSDATE
		, USER
	);

	COMMIT;
END;
/


--------------------------------------------------------
--  DDL for Procedure SP_UPDATE_FORM_DATA
--------------------------------------------------------

/**
 * Stores the form data XML in the form detail table (FORM_DTL).
 *
 * @param IO_ID - ID number the row of the FORM_DTL table to be inserted or updated.  It will be also used as the return object.
 * @param I_FORM_TYPE - Form Type to indicate the source form name, which will be
 * 				used to distinguish the xml structure.
 * @param I_FIELD_DATA - CLOB representation of the form xml data.
 * @param I_USER - Indicates the user who
 * @param I_PROCID - Process ID for the process instance associated with the given form data.
 * @param I_ACTSEQ - Activity Sequence for the process instance associated with the given form data.
 * @param I_WITEMSEQ - Work Item Sequence for the process instance associated with the given form data.
 *
 * @return IO_ID - ID number of the row of the FORM_DTL table inserted or updated.
 */

CREATE OR REPLACE PROCEDURE SP_UPDATE_FORM_DATA
(
	IO_ID               IN OUT  NUMBER
	, I_FORM_TYPE       IN      VARCHAR2
	, I_FIELD_DATA      IN      CLOB
	, I_USER            IN      VARCHAR2
	, I_PROCID          IN      NUMBER
	, I_ACTSEQ          IN      NUMBER
	, I_WITEMSEQ        IN      NUMBER
)
IS
	V_ID NUMBER(20);
	V_FORM_TYPE VARCHAR2(50);
	V_USER VARCHAR2(50);
	V_PROCID NUMBER(10);
	V_ACTSEQ NUMBER(10);
	V_WITEMSEQ NUMBER(10);
	V_REC_CNT NUMBER(10);
	V_MAX_ID NUMBER(20);
	V_XMLDOC XMLTYPE;
	V_REMAINING_SLA NUMBER;
	V_DEADLINE_SEQ1 NUMBER;
	V_DEADLINE_SEQ2 NUMBER;
BEGIN
	V_XMLDOC := XMLTYPE(I_FIELD_DATA);

	IF IO_ID IS NOT NULL AND IO_ID > 0 THEN
		V_ID := IO_ID;
	ELSE

		-- if existing record is found using procid, use that id
		IF I_PROCID IS NOT NULL AND I_PROCID > 0 THEN
			BEGIN
				SELECT ID INTO V_ID FROM FORM_DTL WHERE PROCID = I_PROCID;
			EXCEPTION
				WHEN NO_DATA_FOUND THEN
					V_ID := -1;
			END;
		END IF;

		IO_ID := V_ID;
	END IF;

	IF I_PROCID IS NOT NULL AND I_PROCID > 0 THEN
		V_PROCID := I_PROCID;
	ELSE
		V_PROCID := 0;
	END IF;

	IF I_ACTSEQ IS NOT NULL AND I_ACTSEQ > 0 THEN
		V_ACTSEQ := I_ACTSEQ;
	ELSE
		V_ACTSEQ := 0;
	END IF;

	IF I_WITEMSEQ IS NOT NULL AND I_WITEMSEQ > 0 THEN
		V_WITEMSEQ := I_WITEMSEQ;
	ELSE
		V_WITEMSEQ := 0;
	END IF;

	BEGIN
		SELECT COUNT(*) INTO V_REC_CNT FROM FORM_DTL WHERE ID = V_ID;
	EXCEPTION
		WHEN NO_DATA_FOUND THEN
			V_REC_CNT := -1;
	END;

	IF V_ACTSEQ = 8 THEN
		SP_UPDATE_PV_FROM_FORMDATA_SC(V_PROCID, V_XMLDOC);
	ELSE
		SP_UPDATE_PV_FROM_FORMDATA(V_PROCID, V_XMLDOC);
	END IF;

	SP_UPDATE_REPORT_FROM_FORMDATA(V_PROCID, V_XMLDOC);

	-- do not save pv_requestStatus to get latest from PV value
	SELECT UPDATEXML(V_XMLDOC, '/formData/items/item[id="pv_requestStatus"]', '')
      INTO V_XMLDOC
      FROM DUAL;
	  
	V_FORM_TYPE := I_FORM_TYPE;
	V_USER := I_USER;

	IF V_REC_CNT > 0 THEN
		UPDATE FORM_DTL
		SET
			PROCID = V_PROCID
			, ACTSEQ = V_ACTSEQ
			, WITEMSEQ = V_WITEMSEQ
			, FIELD_DATA = V_XMLDOC
			, MOD_DT = SYSDATE
			, MOD_USR = V_USER
		WHERE ID = V_ID
		;

	ELSE
		INSERT INTO FORM_DTL
		(
			PROCID
			, ACTSEQ
			, WITEMSEQ
			, FORM_TYPE
			, FIELD_DATA
			, CRT_DT
			, CRT_USR
		)
		VALUES
		(
			V_PROCID
			, V_ACTSEQ
			, V_WITEMSEQ
			, V_FORM_TYPE
			, V_XMLDOC
			, SYSDATE
			, V_USER
		)
		;
	END IF;
	
	-- adjust deadline to resume 60 day clock
	IF V_ACTSEQ = 7 THEN
		SELECT MAX(ROUND((startdtime - SYSDATE), 0)) INTO V_REMAINING_SLA FROM bizflow.deadline WHERE procid = I_PROCID AND actseq=7;
		SELECT COUNT(*) INTO V_REC_CNT FROM HHS_IHS_HR.send_email WHERE parent_id = I_PROCID AND rcv_dt IS NULL;

		-- if greater than 60 days, it is on hold
		IF V_REMAINING_SLA > 60 AND V_REC_CNT = 0 THEN
			SELECT MIN(REMAINING_SLA) INTO V_REMAINING_SLA FROM SEND_EMAIL WHERE PARENT_ID = I_PROCID;
			SELECT MIN(deadlineseq) INTO V_DEADLINE_SEQ1 FROM bizflow.deadline WHERE procid = I_PROCID AND actseq=7;
			SELECT MAX(deadlineseq) INTO V_DEADLINE_SEQ2 FROM bizflow.deadline WHERE procid = I_PROCID AND actseq=7;
			UPDATE bizflow.deadline SET startdtime = (SYSDATE + V_REMAINING_SLA/60/24), nextdtime = (SYSDATE + V_REMAINING_SLA/60/24) WHERE procid = I_PROCID AND actseq=7 AND deadlineseq = V_DEADLINE_SEQ1;
			
			IF V_DEADLINE_SEQ1 != V_DEADLINE_SEQ2 THEN
				UPDATE bizflow.deadline SET startdtime = (SYSDATE + V_REMAINING_SLA/60/24 + 30), nextdtime = (SYSDATE + V_REMAINING_SLA/60/24 + 30) WHERE procid = I_PROCID AND actseq=7 AND deadlineseq = V_DEADLINE_SEQ2;
			END IF;

			UPDATE BIZFLOW.rlvntdata SET value = 'Pending Classification' WHERE procid = I_PROCID AND rlvntdataname = 'requestStatus';
		END IF;
	END IF;

	COMMIT;

EXCEPTION
	WHEN OTHERS THEN
		SP_ERROR_LOG();
END;

/

--------------------------------------------------------
--  DDL for Procedure SP_UPDATE_PV_FROM_FORMDATA
--------------------------------------------------------

/**
 * Parses the form data xml to retrieve process variable values,
 * and updates process variable table (BIZFLOW.RLVNTDATA) records for the respective
 * the Strategic Consultation process instance identified by the Process ID.
 *
 * @param I_PROCID - Process ID for the target process instance whose process variables should be updated.
 * @param I_FIELD_DATA - Form data xml.
 */

CREATE OR REPLACE PROCEDURE SP_UPDATE_PV_FROM_FORMDATA
(
	I_PROCID            IN      NUMBER
	, I_FIELD_DATA      IN      XMLTYPE
)
IS
	V_RLVNTDATANAME        VARCHAR2(100);
	V_VALUE                NVARCHAR2(2000);
	V_VALUE2               NVARCHAR2(2000);
	V_PN                   NVARCHAR2(2000);
	V_VN                   NVARCHAR2(2000);
	V_XMLVALUE             XMLTYPE;
	V_XMLVALUE2            XMLTYPE;
BEGIN
	IF I_PROCID IS NOT NULL AND I_PROCID > 0 THEN
		V_RLVNTDATANAME := 'positionTitle';
		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="positionTitle"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VALUE := V_XMLVALUE.GETSTRINGVAL();
		ELSE
			V_VALUE := NULL;
		END IF;
		UPDATE BIZFLOW.RLVNTDATA SET VALUE = V_VALUE WHERE RLVNTDATANAME = V_RLVNTDATANAME AND PROCID = I_PROCID;

		V_RLVNTDATANAME := 'actionType';
		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="actionType"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VALUE := V_XMLVALUE.GETSTRINGVAL();
			UPDATE BIZFLOW.RLVNTDATA SET VALUE = V_VALUE WHERE RLVNTDATANAME = V_RLVNTDATANAME AND PROCID = I_PROCID;
		END IF;

		V_RLVNTDATANAME := 'classificationStatus';
		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="classificationStat"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VALUE := V_XMLVALUE.GETSTRINGVAL();
			UPDATE BIZFLOW.RLVNTDATA SET VALUE = V_VALUE WHERE RLVNTDATANAME = V_RLVNTDATANAME AND PROCID = I_PROCID;
		END IF;

		V_RLVNTDATANAME := 'requestStatus';
		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="pv_requestStatus"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VALUE := V_XMLVALUE.GETSTRINGVAL();
			UPDATE BIZFLOW.RLVNTDATA SET VALUE = V_VALUE WHERE RLVNTDATANAME = V_RLVNTDATANAME AND PROCID = I_PROCID;
		END IF;

		----------------------------------------------------------------------------------------------------------
		V_RLVNTDATANAME := 'pp_s_g';
		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="payPlan"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VALUE := CONCAT(V_XMLVALUE.GETSTRINGVAL(), '-');
		ELSE
			V_VALUE := '-';
		END IF;

		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="series"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VALUE2 := V_XMLVALUE.GETSTRINGVAL();
			IF (INSTR(V_VALUE2, ',') > 0) THEN
				V_VALUE := CONCAT(CONCAT(V_VALUE, 'Interdisciplinary'), '-');
			ELSE
				V_VALUE := CONCAT(CONCAT(V_VALUE, V_VALUE2), '-');
			END IF;
		ELSE
			V_VALUE := CONCAT(V_VALUE, '-');
		END IF;

		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="selectGrades"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VALUE := CONCAT(V_VALUE, REPLACE(REPLACE(REPLACE(REPLACE(V_XMLVALUE.GETSTRINGVAL(), ',', '/'), ':', ''), 'Y', ''), 'N', ''));
		END IF;
		UPDATE BIZFLOW.RLVNTDATA SET VALUE = V_VALUE WHERE RLVNTDATANAME = V_RLVNTDATANAME AND PROCID = I_PROCID;

		----------------------------------------------------------------------------------------------------------
		V_RLVNTDATANAME := 'pn_jc_vn';
		V_VALUE := 'Position Number: ';
		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="positionNumber"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_PN := V_XMLVALUE.GETSTRINGVAL();
		ELSE
			V_PN := NULL;
		END IF;

		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="positionNumber_2"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VALUE2 := V_XMLVALUE.GETSTRINGVAL();
			IF V_PN IS NULL THEN
				V_PN := V_VALUE2;
			ELSE
				V_PN := CONCAT(CONCAT(V_PN, ','), V_VALUE2);
			END IF;
		END IF;

		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="positionNumber_3"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VALUE2 := V_XMLVALUE.GETSTRINGVAL();
			IF V_PN IS NULL THEN
				V_PN := V_VALUE2;
			ELSE
				V_PN := CONCAT(CONCAT(V_PN, ','), V_VALUE2);
			END IF;
		END IF;

		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="positionNumber_4"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VALUE2 := V_XMLVALUE.GETSTRINGVAL();
			IF V_PN IS NULL THEN
				V_PN := V_VALUE2;
			ELSE
				V_PN := CONCAT(CONCAT(V_PN, ','), V_VALUE2);
			END IF;
		END IF;

		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="positionNumber_5"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VALUE2 := V_XMLVALUE.GETSTRINGVAL();
			IF V_PN IS NULL THEN
				V_PN := V_VALUE2;
			ELSE
				V_PN := CONCAT(CONCAT(V_PN, ','), V_VALUE2);
			END IF;
		END IF;

		V_VALUE := CONCAT(V_VALUE, V_PN);
		V_VALUE := CONCAT(V_VALUE, ', Job Code Number: ');

		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="jobCode_2"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VALUE := CONCAT(V_VALUE, V_XMLVALUE.GETSTRINGVAL());
		END IF;

		V_VALUE := CONCAT(V_VALUE, ', Vice Name: ');

		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="viceName"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VN := V_XMLVALUE.GETSTRINGVAL();
		ELSE
			V_VN := NULL;
		END IF;

		V_XMLVALUE2 := I_FIELD_DATA.EXTRACT('/formData/items/item[id="viceName_2"]/value/text()');
		IF V_XMLVALUE2 IS NOT NULL THEN
			V_VALUE2 := V_XMLVALUE2.GETSTRINGVAL();
			IF V_VN IS NULL THEN
				V_VN := V_VALUE2;
			ELSE
				V_VN := CONCAT(CONCAT(V_VN, ', '), V_VALUE2);
			END IF;
		END IF;

		V_XMLVALUE2 := I_FIELD_DATA.EXTRACT('/formData/items/item[id="viceName_3"]/value/text()');
		IF V_XMLVALUE2 IS NOT NULL THEN
			V_VALUE2 := V_XMLVALUE2.GETSTRINGVAL();
			IF V_VN IS NULL THEN
				V_VN := V_VALUE2;
			ELSE
				V_VN := CONCAT(CONCAT(V_VN, ', '), V_VALUE2);
			END IF;
		END IF;

		V_XMLVALUE2 := I_FIELD_DATA.EXTRACT('/formData/items/item[id="viceName_4"]/value/text()');
		IF V_XMLVALUE2 IS NOT NULL THEN
			V_VALUE2 := V_XMLVALUE2.GETSTRINGVAL();
			IF V_VN IS NULL THEN
				V_VN := V_VALUE2;
			ELSE
				V_VN := CONCAT(CONCAT(V_VN, ', '), V_VALUE2);
			END IF;
		END IF;

		V_XMLVALUE2 := I_FIELD_DATA.EXTRACT('/formData/items/item[id="viceName_5"]/value/text()');
		IF V_XMLVALUE2 IS NOT NULL THEN
			V_VALUE2 := V_XMLVALUE2.GETSTRINGVAL();
			IF V_VN IS NULL THEN
				V_VN := V_VALUE2;
			ELSE
				V_VN := CONCAT(CONCAT(V_VN, ', '), V_VALUE2);
			END IF;
		END IF;

		V_VALUE := CONCAT(V_VALUE, V_VN);
		UPDATE BIZFLOW.RLVNTDATA SET VALUE = V_VALUE WHERE RLVNTDATANAME = V_RLVNTDATANAME AND PROCID = I_PROCID;
		----------------------------------------------------------------------------------------------------------

		
		V_RLVNTDATANAME := 'adminCode';
		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="adminCode"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_XMLVALUE2 := I_FIELD_DATA.EXTRACT('/formData/items/item[id="adminCodeDesc"]/value/text()');
			V_VALUE := CONCAT(CONCAT(V_XMLVALUE.GETSTRINGVAL(), ' - '), V_XMLVALUE2.GETSTRINGVAL());
		ELSE
			V_VALUE := NULL;
		END IF;
		UPDATE BIZFLOW.RLVNTDATA SET VALUE = V_VALUE WHERE RLVNTDATANAME = V_RLVNTDATANAME AND PROCID = I_PROCID;

		-- update participant PV hiringManager
		V_RLVNTDATANAME := 'hiringManager';
		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="managerID"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VALUE := CONCAT('[U]', V_XMLVALUE.GETSTRINGVAL());
			UPDATE BIZFLOW.RLVNTDATA SET VALUE = V_VALUE WHERE RLVNTDATANAME = V_RLVNTDATANAME AND PROCID = I_PROCID;
		END IF;

		-- update participant PV classifier
		V_RLVNTDATANAME := 'classifier';
		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="HRClassifier"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VALUE := CONCAT('[U]', V_XMLVALUE.GETSTRINGVAL());
			UPDATE BIZFLOW.RLVNTDATA SET VALUE = V_VALUE WHERE RLVNTDATANAME = V_RLVNTDATANAME AND PROCID = I_PROCID;
		END IF;

		-- update participant PV specialist
		V_RLVNTDATANAME := 'specialist';
		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="HRSpecialist"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VALUE := CONCAT('[U]', V_XMLVALUE.GETSTRINGVAL());
			UPDATE BIZFLOW.RLVNTDATA SET VALUE = V_VALUE WHERE RLVNTDATANAME = V_RLVNTDATANAME AND PROCID = I_PROCID;
		END IF;
		
		-- update participant PV consultant
		V_RLVNTDATANAME := 'consultant';
		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="consultant"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VALUE := CONCAT('[U]', V_XMLVALUE.GETSTRINGVAL());
			UPDATE BIZFLOW.RLVNTDATA SET VALUE = V_VALUE WHERE RLVNTDATANAME = V_RLVNTDATANAME AND PROCID = I_PROCID;
		END IF;
		
		V_RLVNTDATANAME := 'attachDocType';
		SELECT LISTAGG(category, ',') WITHIN GROUP (ORDER BY category) INTO V_VALUE FROM BIZFLOW.attach WHERE procid = I_PROCID;
		UPDATE BIZFLOW.RLVNTDATA SET VALUE = V_VALUE WHERE RLVNTDATANAME = V_RLVNTDATANAME AND PROCID = I_PROCID;
	END IF;

EXCEPTION
	WHEN OTHERS THEN
		SP_ERROR_LOG();
END;

/


--------------------------------------------------------
--  DDL for Procedure SP_UPDATE_PV_FROM_FORMDATA_SC
--------------------------------------------------------

/**
 * Parses the form data xml to retrieve process variable values,
 * and updates process variable table (BIZFLOW.RLVNTDATA) records for the respective
 * the Strategic Consultation process instance identified by the Process ID.
 *
 * @param I_PROCID - Process ID for the target process instance whose process variables should be updated.
 * @param I_FIELD_DATA - Form data xml.
 */

CREATE OR REPLACE PROCEDURE SP_UPDATE_PV_FROM_FORMDATA_SC
(
	I_PROCID            IN      NUMBER
	, I_FIELD_DATA      IN      XMLTYPE
)
IS
	V_RLVNTDATANAME        VARCHAR2(100);
	V_VALUE                NVARCHAR2(2000);
	V_VALUE2               NVARCHAR2(2000);
	V_PN                   NVARCHAR2(2000);
	V_VN                   NVARCHAR2(2000);
	V_XMLVALUE             XMLTYPE;
	V_XMLVALUE2            XMLTYPE;
BEGIN
	IF I_PROCID IS NOT NULL AND I_PROCID > 0 THEN
		-- update participant PV gateKeeper based on admin code
		V_RLVNTDATANAME := 'gateKeeper';
		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="adminCode"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			SELECT memberid INTO V_VALUE FROM BIZFLOW.parentmember WHERE memberpath = 
			(CASE WHEN (V_XMLVALUE.GETSTRINGVAL() = 'GANC8' OR V_XMLVALUE.GETSTRINGVAL() LIKE 'GFC%' OR V_XMLVALUE.GETSTRINGVAL() LIKE 'GFH%' OR V_XMLVALUE.GETSTRINGVAL() LIKE 'GFK%') THEN '/IHS Recruitment/Root/Gate Keeper/SOUTHEAST REGION HR RESOURCES'
				WHEN (V_XMLVALUE.GETSTRINGVAL() = 'GANC6' OR V_XMLVALUE.GETSTRINGVAL() LIKE 'GFL%' OR V_XMLVALUE.GETSTRINGVAL() LIKE 'GFMN%') THEN '/IHS Recruitment/Root/Gate Keeper/SOUTHWEST REGION HR RESOURCES'
				WHEN (V_XMLVALUE.GETSTRINGVAL() = 'GANC4' OR V_XMLVALUE.GETSTRINGVAL() LIKE 'GFB%' OR V_XMLVALUE.GETSTRINGVAL() LIKE 'GFM%' OR V_XMLVALUE.GETSTRINGVAL() LIKE 'GFG%') THEN '/IHS Recruitment/Root/Gate Keeper/WESTERN REGION HR RESOURCES CE'
				WHEN (V_XMLVALUE.GETSTRINGVAL() = 'GANC5' OR V_XMLVALUE.GETSTRINGVAL() LIKE 'GFE%' OR V_XMLVALUE.GETSTRINGVAL() LIKE 'GFF%' OR V_XMLVALUE.GETSTRINGVAL() LIKE 'GFA%') THEN '/IHS Recruitment/Root/Gate Keeper/NORTHERN PLAINS REGION HR RESO'
				WHEN (V_XMLVALUE.GETSTRINGVAL() = 'GANC7' OR V_XMLVALUE.GETSTRINGVAL() LIKE 'GFJ%') THEN '/IHS Recruitment/Root/Gate Keeper/NAVAJO REGION HR RESOURCES CEN'
				ELSE '/IHS Recruitment/Root/Gate Keeper/Headquarters'
			END);
			V_VALUE := CONCAT('[G]', V_VALUE);
			UPDATE BIZFLOW.RLVNTDATA SET VALUE = V_VALUE WHERE RLVNTDATANAME = V_RLVNTDATANAME AND PROCID = I_PROCID;
		END IF;

		V_RLVNTDATANAME := 'requestStatus';
		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="pv_requestStatus"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VALUE := V_XMLVALUE.GETSTRINGVAL();
			UPDATE BIZFLOW.RLVNTDATA SET VALUE = V_VALUE WHERE RLVNTDATANAME = V_RLVNTDATANAME AND PROCID = I_PROCID;
		END IF;

		-- update participant PV specialist
		V_RLVNTDATANAME := 'specialist';
		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="HRSpecialist"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VALUE := CONCAT('[U]', V_XMLVALUE.GETSTRINGVAL());
			UPDATE BIZFLOW.RLVNTDATA SET VALUE = V_VALUE WHERE RLVNTDATANAME = V_RLVNTDATANAME AND PROCID = I_PROCID;
		END IF;
		
		-- update participant PV consultant
		V_RLVNTDATANAME := 'consultant';
		V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="consultant"]/value/text()');
		IF V_XMLVALUE IS NOT NULL THEN
			V_VALUE := CONCAT('[U]', V_XMLVALUE.GETSTRINGVAL());
			UPDATE BIZFLOW.RLVNTDATA SET VALUE = V_VALUE WHERE RLVNTDATANAME = V_RLVNTDATANAME AND PROCID = I_PROCID;
		END IF;
		
		V_RLVNTDATANAME := 'attachDocType';
		SELECT LISTAGG(category, ',') WITHIN GROUP (ORDER BY category) INTO V_VALUE FROM BIZFLOW.attach WHERE procid = I_PROCID;
		UPDATE BIZFLOW.RLVNTDATA SET VALUE = V_VALUE WHERE RLVNTDATANAME = V_RLVNTDATANAME AND PROCID = I_PROCID;
	END IF;

EXCEPTION
	WHEN OTHERS THEN
		SP_ERROR_LOG();
END;

/

--------------------------------------------------------
--  DDL for Procedure SP_UPDATE_REPORT_FROM_FORMDATA
--------------------------------------------------------

CREATE OR REPLACE PROCEDURE SP_UPDATE_REPORT_FROM_FORMDATA
(
	I_PROCID            IN      NUMBER
	, I_FIELD_DATA      IN      XMLTYPE
)
IS
	V_INITIATOR		                VARCHAR2(100);
	V_ACTION_TYPE	                VARCHAR2(100);
	V_CLASSIFIER	                VARCHAR2(100);
	V_HR_MANAGER	                VARCHAR2(100);
	V_HR_SPECIALIST	                VARCHAR2(100);
	V_CANCEL_REASON	                VARCHAR2(100);
	V_PAY_PLAN		                VARCHAR2(100);
	V_SERIES		                VARCHAR2(4000);
	V_JOB_CODE		                VARCHAR2(100);
	V_POSITION_TITLE	            VARCHAR2(100);
	V_POSITION_NUMBER               VARCHAR2(100);
	V_VICE_NAME			            VARCHAR2(500);
	V_ADMIN_CODE	                VARCHAR2(100);
	V_GRADE			                VARCHAR2(50);
	V_PN_COUNT	                	VARCHAR2(10);
	V_VACATED_DATE	                VARCHAR2(100);
	V_ADMIN_CODE_DESCRIPTION	    VARCHAR2(100);
	V_DUTY_STATION	                VARCHAR2(2000);
	V_OFFICE_LOCATION	            VARCHAR2(50);
	V_APPOINTMENT_TYPE	            VARCHAR2(500);
	V_TEMPORARY_REASON	            VARCHAR2(500);
	V_HIRING_PLAN	                VARCHAR2(200);
	V_ADDITIONAL_HIRING_PLAN	    VARCHAR2(100);
	V_SELECTING_OFFICIAL	        VARCHAR2(100);
	V_PCN	                		VARCHAR2(10);
	V_CAN	                		VARCHAR2(10);
	V_SC_COMMENT	                VARCHAR2(3000);
	V_CLS_COMMENT	                VARCHAR2(3000);
	V_HR_COMMENT	                VARCHAR2(3000);
	V_ADVERTISE_GRADE	            VARCHAR2(100);
	V_TARGET_GRADE	                VARCHAR2(2);
	V_WORKING_HOURS	                VARCHAR2(10);
	V_WORK_SCHEDULE	                VARCHAR2(20);
	V_WAY_CLOSE	                	VARCHAR2(20);
	V_CUT_OFF	                	VARCHAR2(10);
	V_ENTICEMENT	                VARCHAR2(200);
	V_SPF	                		VARCHAR2(5);
	V_COMPLETED_JA	                VARCHAR2(5);
	V_SPECIAL_EXP	                VARCHAR2(3000);
	V_ADDITIONAL_REC	            VARCHAR2(100);
	V_OTHER_REC	                	VARCHAR2(200);
	V_SME	                		VARCHAR2(200);
	V_REQ_LICENSURE	                VARCHAR2(5);
	V_LAW101630	                	VARCHAR2(5);
	V_WAIT_9_MONTHS	                VARCHAR2(5);
	V_WAIT_MONTHS	                VARCHAR2(10);
	V_REQ_SHIFT	                	VARCHAR2(5);
	V_STANDBY	                	VARCHAR2(5);
	V_ONCALL	                	VARCHAR2(5);
	V_TRAVEL	                	VARCHAR2(20);
	V_OTHER_CONDITION	            VARCHAR2(100);
	V_REQ_CREDENTIAL	            VARCHAR2(5);
	V_REQ_DRUGTEST	                VARCHAR2(5);
	V_ESSENTIAL	                	VARCHAR2(5);
	V_REQ_IMMUNIZATION	            VARCHAR2(5);
	V_REQ_PHYSICAL	                VARCHAR2(5);
	V_REQ_FD	                	VARCHAR2(5);
	V_REQ_SUP_PROBATION	            VARCHAR2(5);
	V_CLEARANCE	                	VARCHAR2(30);
	V_SPECIAL_SALARY_RATE	        VARCHAR2(5);
	V_PAY_TABLE	                	VARCHAR2(10);
	V_XMLVALUE             			XMLTYPE;
	V_REC_CNT						NUMBER(10);
BEGIN
	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="positionTitle"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_POSITION_TITLE := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_POSITION_TITLE := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="actionType"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_ACTION_TYPE := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_ACTION_TYPE := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="payPlan"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_PAY_PLAN := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_PAY_PLAN := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="series"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_SERIES := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_SERIES := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="selectGrades"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_GRADE := REPLACE(REPLACE(REPLACE(REPLACE(V_XMLVALUE.GETSTRINGVAL(), ',', '/'), ':', ''), 'Y', ''), 'N', '');
	ELSE
		V_GRADE := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="positionNumber"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_POSITION_NUMBER := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_POSITION_NUMBER := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="numberOfVacancies"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_PN_COUNT := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_PN_COUNT := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="positionNumber_2"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_POSITION_NUMBER IS NULL THEN
				V_POSITION_NUMBER := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_POSITION_NUMBER := CONCAT(CONCAT(V_POSITION_NUMBER, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="positionNumber_3"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_POSITION_NUMBER IS NULL THEN
				V_POSITION_NUMBER := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_POSITION_NUMBER := CONCAT(CONCAT(V_POSITION_NUMBER, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="positionNumber_4"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_POSITION_NUMBER IS NULL THEN
				V_POSITION_NUMBER := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_POSITION_NUMBER := CONCAT(CONCAT(V_POSITION_NUMBER, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="positionNumber_5"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_POSITION_NUMBER IS NULL THEN
				V_POSITION_NUMBER := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_POSITION_NUMBER := CONCAT(CONCAT(V_POSITION_NUMBER, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="jobCode_2"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_JOB_CODE := V_XMLVALUE.GETSTRINGVAL();
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="viceName"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_VICE_NAME := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_VICE_NAME := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="viceName_2"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_VICE_NAME IS NULL THEN
				V_VICE_NAME := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_VICE_NAME := CONCAT(CONCAT(V_VICE_NAME, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="viceName_3"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_VICE_NAME IS NULL THEN
				V_VICE_NAME := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_VICE_NAME := CONCAT(CONCAT(V_VICE_NAME, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="viceName_4"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_VICE_NAME IS NULL THEN
				V_VICE_NAME := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_VICE_NAME := CONCAT(CONCAT(V_VICE_NAME, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="viceName_5"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_VICE_NAME IS NULL THEN
				V_VICE_NAME := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_VICE_NAME := CONCAT(CONCAT(V_VICE_NAME, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;
	
	-- vacated date loop begin
	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="positionVacatedDate"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_VACATED_DATE := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_VACATED_DATE := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="positionVacatedDate_2"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_VACATED_DATE IS NULL THEN
				V_VACATED_DATE := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_VACATED_DATE := CONCAT(CONCAT(V_VACATED_DATE, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="positionVacatedDate_3"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_VACATED_DATE IS NULL THEN
				V_VACATED_DATE := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_VACATED_DATE := CONCAT(CONCAT(V_VACATED_DATE, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="positionVacatedDate_4"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_VACATED_DATE IS NULL THEN
				V_VACATED_DATE := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_VACATED_DATE := CONCAT(CONCAT(V_VACATED_DATE, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="positionVacatedDate_5"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_VACATED_DATE IS NULL THEN
				V_VACATED_DATE := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_VACATED_DATE := CONCAT(CONCAT(V_VACATED_DATE, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;
	-- vacated date loop end
	
	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="adminCode"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_ADMIN_CODE := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_ADMIN_CODE := NULL;
	END IF;
		
	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="adminCodeDesc"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_ADMIN_CODE_DESCRIPTION := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_ADMIN_CODE_DESCRIPTION := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="dutyLoc"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_DUTY_STATION := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_DUTY_STATION := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="empOfficeLoc"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_OFFICE_LOCATION := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_OFFICE_LOCATION := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="h_selectedAppointmentTypes"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_APPOINTMENT_TYPE := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_APPOINTMENT_TYPE := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="temporaryPositionReason"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_TEMPORARY_REASON := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_TEMPORARY_REASON := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="h_selectedHiringPlan"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_HIRING_PLAN := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_HIRING_PLAN := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="additionalHiringPlan"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_ADDITIONAL_HIRING_PLAN := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_ADDITIONAL_HIRING_PLAN := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="selectingOfficial"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_SELECTING_OFFICIAL := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_SELECTING_OFFICIAL := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="pcn"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_PCN := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_PCN := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="can"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_CAN := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_CAN := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="consultationComments"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_SC_COMMENT := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_SC_COMMENT := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="classificationComments"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_CLS_COMMENT := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_CLS_COMMENT := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="comments"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_HR_COMMENT := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_HR_COMMENT := NULL;
	END IF;

	-- advertise grade loop begin
	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="advertiseGrade1"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_ADVERTISE_GRADE := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_ADVERTISE_GRADE := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="advertiseGrade2"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_ADVERTISE_GRADE IS NULL THEN
				V_ADVERTISE_GRADE := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_ADVERTISE_GRADE := CONCAT(CONCAT(V_ADVERTISE_GRADE, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="advertiseGrade3"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_ADVERTISE_GRADE IS NULL THEN
				V_ADVERTISE_GRADE := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_ADVERTISE_GRADE := CONCAT(CONCAT(V_ADVERTISE_GRADE, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="advertiseGrade4"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_ADVERTISE_GRADE IS NULL THEN
				V_ADVERTISE_GRADE := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_ADVERTISE_GRADE := CONCAT(CONCAT(V_ADVERTISE_GRADE, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="advertiseGrade5"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_ADVERTISE_GRADE IS NULL THEN
				V_ADVERTISE_GRADE := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_ADVERTISE_GRADE := CONCAT(CONCAT(V_ADVERTISE_GRADE, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="advertiseGrade6"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_ADVERTISE_GRADE IS NULL THEN
				V_ADVERTISE_GRADE := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_ADVERTISE_GRADE := CONCAT(CONCAT(V_ADVERTISE_GRADE, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="advertiseGrade7"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_ADVERTISE_GRADE IS NULL THEN
				V_ADVERTISE_GRADE := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_ADVERTISE_GRADE := CONCAT(CONCAT(V_ADVERTISE_GRADE, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="advertiseGrade8"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_ADVERTISE_GRADE IS NULL THEN
				V_ADVERTISE_GRADE := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_ADVERTISE_GRADE := CONCAT(CONCAT(V_ADVERTISE_GRADE, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="advertiseGrade9"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_ADVERTISE_GRADE IS NULL THEN
				V_ADVERTISE_GRADE := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_ADVERTISE_GRADE := CONCAT(CONCAT(V_ADVERTISE_GRADE, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="advertiseGrade10"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_ADVERTISE_GRADE IS NULL THEN
				V_ADVERTISE_GRADE := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_ADVERTISE_GRADE := CONCAT(CONCAT(V_ADVERTISE_GRADE, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="advertiseGrade11"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_ADVERTISE_GRADE IS NULL THEN
				V_ADVERTISE_GRADE := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_ADVERTISE_GRADE := CONCAT(CONCAT(V_ADVERTISE_GRADE, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="advertiseGrade12"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_ADVERTISE_GRADE IS NULL THEN
				V_ADVERTISE_GRADE := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_ADVERTISE_GRADE := CONCAT(CONCAT(V_ADVERTISE_GRADE, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="advertiseGrade13"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_ADVERTISE_GRADE IS NULL THEN
				V_ADVERTISE_GRADE := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_ADVERTISE_GRADE := CONCAT(CONCAT(V_ADVERTISE_GRADE, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="advertiseGrade14"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_ADVERTISE_GRADE IS NULL THEN
				V_ADVERTISE_GRADE := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_ADVERTISE_GRADE := CONCAT(CONCAT(V_ADVERTISE_GRADE, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="advertiseGrade15"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		IF V_ADVERTISE_GRADE IS NULL THEN
				V_ADVERTISE_GRADE := V_XMLVALUE.GETSTRINGVAL();
			ELSE
				V_ADVERTISE_GRADE := CONCAT(CONCAT(V_ADVERTISE_GRADE, ', '), V_XMLVALUE.GETSTRINGVAL());
		END IF;
	END IF;
	-- advertise grade loop end

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="targetGrade"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_TARGET_GRADE := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_TARGET_GRADE := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="numberOfHoursWorkedPerWeek"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_WORKING_HOURS := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_WORKING_HOURS := '40';
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="workSchedule"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_WORK_SCHEDULE := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_WORK_SCHEDULE := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="announcementCloseMode"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_WAY_CLOSE := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_WAY_CLOSE := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="cutOffDate"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_CUT_OFF := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_CUT_OFF := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="recruitmentEnticements"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_ENTICEMENT := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_ENTICEMENT := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="selectivePlacementFactor"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_SPF := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_SPF := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="completedJobAnalysisDated072017"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_COMPLETED_JA := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_COMPLETED_JA := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="specializedExperience"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_SPECIAL_EXP := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_SPECIAL_EXP := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="additionalRecruitment"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_ADDITIONAL_REC := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_ADDITIONAL_REC := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="otherRecruitment"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_OTHER_REC := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_OTHER_REC := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="subjectMatterExpertInfo"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_SME := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_SME := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="conditionRequireLicensure"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_REQ_LICENSURE := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_REQ_LICENSURE := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="conditionChildcare"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_LAW101630 := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_LAW101630 := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="conditionWait"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_WAIT_9_MONTHS := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_WAIT_9_MONTHS := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="conditionWaitMonth"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_WAIT_MONTHS := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_WAIT_MONTHS := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="conditionShiftWork"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_REQ_SHIFT := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_REQ_SHIFT := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="conditionStandbyDuty"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_STANDBY := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_STANDBY := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="conditionOncall"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_ONCALL := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_ONCALL := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="conditionOvernightTravel"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_TRAVEL := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_TRAVEL := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="conditionOther"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_OTHER_CONDITION := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_OTHER_CONDITION := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="conditionCredentialing"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_REQ_CREDENTIAL := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_REQ_CREDENTIAL := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="conditionDrugTesting"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_REQ_DRUGTEST := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_REQ_DRUGTEST := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="conditionEmergencyEssential"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_ESSENTIAL := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_ESSENTIAL := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="conditionImmunizationRecord"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_REQ_IMMUNIZATION := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_REQ_IMMUNIZATION := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="conditionPreEmploymentPhysical"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_REQ_PHYSICAL := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_REQ_PHYSICAL := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="conditionFinancialDisclosure"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_REQ_FD := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_REQ_FD := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="supervisorProbationRequired"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_REQ_SUP_PROBATION := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_REQ_SUP_PROBATION := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="securityClearanceType"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_CLEARANCE := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_CLEARANCE := NULL;
	END IF;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="specialSalaryRate"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_SPECIAL_SALARY_RATE := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_SPECIAL_SALARY_RATE := NULL;
	END IF;

	
	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="payTableNumber"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_PAY_TABLE := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_PAY_TABLE := NULL;
	END IF;
	
	SELECT CREATORNAME INTO V_INITIATOR FROM BIZFLOW.PROCS WHERE PROCID = I_PROCID;

	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="whoToContact"]/value/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_HR_MANAGER := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_HR_MANAGER := NULL;
	END IF;
			
	V_XMLVALUE := I_FIELD_DATA.EXTRACT('/formData/items/item[id="HRClassifier"]/text/text()');
	IF V_XMLVALUE IS NOT NULL THEN
		V_CLASSIFIER := V_XMLVALUE.GETSTRINGVAL();
	ELSE
		V_CLASSIFIER := NULL;
	END IF;

	SELECT DISPVALUE INTO V_HR_SPECIALIST FROM BIZFLOW.RLVNTDATA WHERE PROCID = I_PROCID AND rlvntdataname = 'specialist';
	SELECT VALUE INTO V_CANCEL_REASON FROM BIZFLOW.RLVNTDATA WHERE PROCID = I_PROCID AND rlvntdataname = 'cancelReason';
	
	BEGIN
		SELECT COUNT(*) INTO V_REC_CNT FROM HHS_IHS_HR.IHS_RECRUITEMENT_DATA WHERE TRACKING_NUMBER = I_PROCID;
	EXCEPTION
		WHEN NO_DATA_FOUND THEN
			V_REC_CNT := -1;
	END;

	IF V_REC_CNT > 0 THEN
		UPDATE HHS_IHS_HR.IHS_RECRUITEMENT_DATA
		SET
			ACTION_TYPE = V_ACTION_TYPE,
			INITIATOR = V_INITIATOR,
			CLASSIFIER = V_CLASSIFIER,
			HR_MANAGER = V_HR_MANAGER,
			HR_SPECIALIST = V_HR_SPECIALIST,
			CANCEL_REASON = V_CANCEL_REASON,
			PAY_PLAN = V_PAY_PLAN,
			JOB_CODE = V_JOB_CODE,
			SERIES = V_SERIES,
			GRADE = V_GRADE,
			POSITION_TITLE = V_POSITION_TITLE,
			POSITION_NUMBER = V_POSITION_NUMBER,
			VICE_NAME = V_VICE_NAME,
			ADMIN_CODE = V_ADMIN_CODE,
			PN_COUNT = V_PN_COUNT,
			VACATED_DATE = V_VACATED_DATE,
			ADMIN_CODE_DESCRIPTION = V_ADMIN_CODE_DESCRIPTION,
			DUTY_STATION = V_DUTY_STATION,
			OFFICE_LOCATION = V_OFFICE_LOCATION,
			APPOINTMENT_TYPE = V_APPOINTMENT_TYPE,
			TEMPORARY_REASON = V_TEMPORARY_REASON,
			HIRING_PLAN = V_HIRING_PLAN,
			ADDITIONAL_HIRING_PLAN = V_ADDITIONAL_HIRING_PLAN,
			SELECTING_OFFICIAL = V_SELECTING_OFFICIAL,
			PCN = V_PCN,
			CAN = V_CAN,
			SC_COMMENT = V_SC_COMMENT,
			CLS_COMMENT = V_CLS_COMMENT,
			HR_COMMENT = V_HR_COMMENT,
			ADVERTISE_GRADE = V_ADVERTISE_GRADE,
			TARGET_GRADE = V_TARGET_GRADE,
			WORKING_HOURS = V_WORKING_HOURS,
			WORK_SCHEDULE = V_WORK_SCHEDULE,
			WAY_CLOSE = V_WAY_CLOSE,
			CUT_OFF = V_CUT_OFF,
			ENTICEMENT = V_ENTICEMENT,
			SPF = V_SPF,
			COMPLETED_JA = V_COMPLETED_JA,
			SPECIAL_EXP = V_SPECIAL_EXP,
			ADDITIONAL_REC = V_ADDITIONAL_REC,
			OTHER_REC = V_OTHER_REC,
			SME = V_SME,
			REQ_LICENSURE = V_REQ_LICENSURE,
			LAW101630 = V_LAW101630,
			WAIT_9_MONTHS = V_WAIT_9_MONTHS,
			WAIT_MONTHS = V_WAIT_MONTHS,
			REQ_SHIFT = V_REQ_SHIFT,
			STANDBY = V_STANDBY,
			ONCALL = V_ONCALL,
			TRAVEL = V_TRAVEL,
			OTHER_CONDITION = V_OTHER_CONDITION,
			REQ_CREDENTIAL = V_REQ_CREDENTIAL,
			REQ_DRUGTEST = V_REQ_DRUGTEST,
			ESSENTIAL = V_ESSENTIAL,
			REQ_IMMUNIZATION = V_REQ_IMMUNIZATION,
			REQ_PHYSICAL = V_REQ_PHYSICAL,
			REQ_FD = V_REQ_FD,
			REQ_SUP_PROBATION = V_REQ_SUP_PROBATION,
			CLEARANCE = V_CLEARANCE,
			SPECIAL_SALARY_RATE = V_SPECIAL_SALARY_RATE,
			PAY_TABLE = V_PAY_TABLE
		WHERE TRACKING_NUMBER = I_PROCID;
	ELSE
		INSERT INTO HHS_IHS_HR.IHS_RECRUITEMENT_DATA
		(
			TRACKING_NUMBER,
			ACTION_TYPE,
			INITIATOR,
			CLASSIFIER,
			HR_MANAGER,
			HR_SPECIALIST,
			CANCEL_REASON,
			PAY_PLAN,
			JOB_CODE,
			SERIES,
			GRADE,
			POSITION_TITLE,
			PN_COUNT,
			POSITION_NUMBER,
			VICE_NAME,
			VACATED_DATE,
			ADMIN_CODE,
			ADMIN_CODE_DESCRIPTION,
			DUTY_STATION,
			OFFICE_LOCATION,
			APPOINTMENT_TYPE,
			TEMPORARY_REASON,
			HIRING_PLAN,
			ADDITIONAL_HIRING_PLAN,
			SELECTING_OFFICIAL,
			PCN,
			CAN,
			SC_COMMENT,
			CLS_COMMENT,
			HR_COMMENT,
			ADVERTISE_GRADE,
			TARGET_GRADE,
			WORKING_HOURS,
			WORK_SCHEDULE,
			WAY_CLOSE,
			CUT_OFF,
			ENTICEMENT,
			SPF,
			COMPLETED_JA,
			SPECIAL_EXP,
			ADDITIONAL_REC,
			OTHER_REC,
			SME,
			REQ_LICENSURE,
			LAW101630,
			WAIT_9_MONTHS,
			WAIT_MONTHS,
			REQ_SHIFT,
			STANDBY,
			ONCALL,
			TRAVEL,
			OTHER_CONDITION,
			REQ_CREDENTIAL,
			REQ_DRUGTEST,
			ESSENTIAL,
			REQ_IMMUNIZATION,
			REQ_PHYSICAL,
			REQ_FD,
			REQ_SUP_PROBATION,
			CLEARANCE,
			SPECIAL_SALARY_RATE,
			PAY_TABLE
		)
		VALUES
		(
			I_PROCID,
			V_ACTION_TYPE,
			V_INITIATOR,
			V_CLASSIFIER,
			V_HR_MANAGER,
			V_HR_SPECIALIST,
			V_CANCEL_REASON,
			V_PAY_PLAN,
			V_JOB_CODE,
			V_SERIES,
			V_GRADE,
			V_POSITION_TITLE,
			V_PN_COUNT,
			V_POSITION_NUMBER,
			V_VICE_NAME,
			V_VACATED_DATE,
			V_ADMIN_CODE,
			V_ADMIN_CODE_DESCRIPTION,
			V_DUTY_STATION,
			V_OFFICE_LOCATION,
			V_APPOINTMENT_TYPE,
			V_TEMPORARY_REASON,
			V_HIRING_PLAN,
			V_ADDITIONAL_HIRING_PLAN,
			V_SELECTING_OFFICIAL,
			V_PCN,
			V_CAN,
			V_SC_COMMENT,
			V_CLS_COMMENT,
			V_HR_COMMENT,
			V_ADVERTISE_GRADE,
			V_TARGET_GRADE,
			V_WORKING_HOURS,
			V_WORK_SCHEDULE,
			V_WAY_CLOSE,
			V_CUT_OFF,
			V_ENTICEMENT,
			V_SPF,
			V_COMPLETED_JA,
			V_SPECIAL_EXP,
			V_ADDITIONAL_REC,
			V_OTHER_REC,
			V_SME,
			V_REQ_LICENSURE,
			V_LAW101630,
			V_WAIT_9_MONTHS,
			V_WAIT_MONTHS,
			V_REQ_SHIFT,
			V_STANDBY,
			V_ONCALL,
			V_TRAVEL,
			V_OTHER_CONDITION,
			V_REQ_CREDENTIAL,
			V_REQ_DRUGTEST,
			V_ESSENTIAL,
			V_REQ_IMMUNIZATION,
			V_REQ_PHYSICAL,
			V_REQ_FD,
			V_REQ_SUP_PROBATION,
			V_CLEARANCE,
			V_SPECIAL_SALARY_RATE,
			V_PAY_TABLE
		);
	END IF;
	
EXCEPTION
	WHEN OTHERS THEN
		SP_ERROR_LOG();
END;

/



--------------------------------------------------------
--  DDL for Procedure SP_SEND_EMAIL
--------------------------------------------------------

create or replace PROCEDURE SP_SEND_EMAIL
(
	I_PROCID            IN  NUMBER
	, I_SENDERID        IN  VARCHAR2 -- Format: [U]??????????
	, I_RECIPIENTID     IN  VARCHAR2 -- Format: [U]??????????
    , I_CCID            IN  VARCHAR2 -- Format: [U]??????????
    , I_REQUESTID       IN  VARCHAR2 -- UUID
	, I_BODY            IN  VARCHAR2
)
IS
	V_REMAINING_SLA NUMBER;
BEGIN
	-- get remaining SLA. If bigger than 60, the deadline is already set to future by previous email
	SELECT MAX(ROUND((startdtime - SYSDATE), 0)) INTO V_REMAINING_SLA FROM bizflow.deadline WHERE procid = I_PROCID AND actseq=7;

	IF V_REMAINING_SLA > 60 THEN
		SELECT MIN(REMAINING_SLA) INTO V_REMAINING_SLA FROM SEND_EMAIL WHERE PARENT_ID = I_PROCID AND RCV_DT IS NULL;
	ELSE
		SELECT MIN(ROUND((startdtime - SYSDATE)*60*24, 0)) INTO V_REMAINING_SLA FROM bizflow.deadline WHERE procid = I_PROCID AND actseq=7;
		UPDATE bizflow.deadline SET startdtime = ADD_MONTHS(startdtime, 60), nextdtime = ADD_MONTHS(nextdtime, 60) WHERE procid = I_PROCID AND actseq=7;
	END IF;

    INSERT INTO SEND_EMAIL (PARENT_ID, SENDER_ID, RECIPIENT_ID, EMAIL_BODY, CRT_DT, REMAINING_SLA, CC_ID, REQUEST_ID)
		VALUES (I_PROCID, I_SENDERID, I_RECIPIENTID, I_BODY, SYSDATE, V_REMAINING_SLA, I_CCID, I_REQUESTID);

	UPDATE BIZFLOW.rlvntdata SET value = 'Pending More Information' WHERE procid = I_PROCID AND rlvntdataname = 'requestStatus';

EXCEPTION
	WHEN OTHERS THEN
		SP_ERROR_LOG();
END;
/

--------------------------------------------------------
--  DDL for Procedure SP_STOP_MANAGER_REMINDER
--------------------------------------------------------

create or replace PROCEDURE SP_STOP_MANAGER_REMINDER
(
    I_REQUESTID       IN  VARCHAR2 -- UUID
	, I_RCV_DT        IN  VARCHAR2
)
IS
	V_PROCID NUMBER DEFAULT 0;
BEGIN
	UPDATE HHS_IHS_HR.SEND_EMAIL SET RCV_DT = TO_DATE(I_RCV_DT, 'MM/DD/YYYY') WHERE REQUEST_ID = I_REQUESTID;

	SELECT MAX(procid) INTO V_PROCID FROM bizflow.rlvntdata WHERE rlvntdataname = 'requestID' AND value = I_REQUESTID;

	IF V_PROCID > 0 THEN
		INSERT INTO complete_wait (PROCESSID, TRUE_COL, CRT_DT) VALUES (V_PROCID, 'T', SYSDATE);
	END IF;
EXCEPTION
	WHEN OTHERS THEN
		SP_ERROR_LOG();
END;
/

--------------------------------------------------------
--  DDL for Procedure SP_ATTACH_AUDIT
--------------------------------------------------------

create or replace PROCEDURE SP_ATTACH_AUDIT
(
    I_EVENTTYPE         IN  VARCHAR2
	, I_PROCID          IN  NUMBER
	, I_USERID          IN  VARCHAR2
	, I_USERNAME        IN  VARCHAR2
	, I_FILENAME        IN  VARCHAR2
	, I_CATEGORY        IN  VARCHAR2
)
IS    
BEGIN
	INSERT INTO ATTACH_AUDIT
	(
        EVENT_TYPE,
        PROCID,
        USER_ID,
        USER_NAME,
        FILENAME,
        CATEGORY,
        CRT_DT
	)
	VALUES (
        I_EVENTTYPE,
        I_PROCID,
        I_USERID,
        I_USERNAME,
        I_FILENAME,
        I_CATEGORY,
	SYSDATE
	);
END;
/

--------------------------------------------------------
--  DDL for Procedure SP_UPDATE_CLASSIFIER
--------------------------------------------------------
create or replace PROCEDURE SP_UPDATE_CLASSIFIER
(
	I_PROCID        IN    NUMBER
	, I_WITEMSEQ    IN    NUMBER  
	, I_MANAGERID   IN    VARCHAR2    
	, I_MANAGERNAME IN    VARCHAR2
)
IS
	V_XMLDOC XMLTYPE;
	V_MANAGERID VARCHAR2(20);
BEGIN
    BEGIN
        SELECT F.FIELD_DATA INTO V_XMLDOC 
          FROM FORM_DTL F, BIZFLOW.WITEM W 
         WHERE W.PROCID = I_PROCID
           AND W.WITEMSEQ = I_WITEMSEQ
           AND W.STATE IN ('I','R','P','V')
           AND F.PROCID = W.PROCID;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20001, 'NO_DATA_FOUND_FROM_DTL');
    END;

    SELECT UPDATEXML(V_XMLDOC, '/formData/items/item[id="HRClassifier"]/value/text()', I_MANAGERID,
                               '/formData/items/item[id="HRClassifier"]/text/text()', I_MANAGERNAME)
      INTO V_XMLDOC
      FROM DUAL;

    UPDATE FORM_DTL SET FIELD_DATA = V_XMLDOC WHERE PROCID = I_PROCID;

    V_MANAGERID := CONCAT('[U]', I_MANAGERID);
    UPDATE BIZFLOW.RLVNTDATA SET VALUE = V_MANAGERID WHERE PROCID = I_PROCID AND RLVNTDATANAME = 'classifier';

EXCEPTION
	WHEN OTHERS THEN
		SP_ERROR_LOG();
END;
/
