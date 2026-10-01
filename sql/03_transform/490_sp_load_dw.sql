-- dw.sp_load_dw: load the warehouse from staging in dependency order, all or nothing.
-- Dimensions first (facts look up their keys), then facts. One transaction around all four calls:
-- the inner procedures see @@TRANCOUNT > 0 and leave commit / rollback to this one.
-- @to_date is passed to the fact load (NULL = everything staged).
USE BankingSectorIntelligence;
GO

CREATE OR ALTER PROCEDURE dw.sp_load_dw
    @to_date DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @own_tran bit = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    BEGIN TRY
        IF @own_tran = 1 BEGIN TRANSACTION;

        EXEC dw.sp_load_dim_date;
        EXEC dw.sp_load_dim_ticker;
        EXEC dw.sp_load_dim_article;
        EXEC dw.sp_load_fact_price_daily @to_date = @to_date;

        IF @own_tran = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own_tran = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
