USE [DMS_RGS_RF_WORK]
GO
/****** Object:  StoredProcedure [dbo].[prepareLPULettersByDate]    Script Date: 18.12.2023 21:27:53 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

--
/*
													-- TODO!!!!! Если что не работает, проверь тут. ДОЛЖЕН СТОЯТЬ КОММЕНТАРИЙ!!!!


20230626 Итак, новый вариант с новым логом посланных писем
20230812 Надо таки навести порядок в отсылке писем и прикинуть, какие исторические данные исключить из расчётов. Подписанность ДС и аннуляция программ
20230814 Поехали плодить и обрабатывать ошибки
20230808 Новый формат таблицы с ошибками. Поддержка апдейта записей
20230827 Попробую альтернативный LEtterFlow_v3
20230830 Ошибочка в цикле создания писем. 
20230903 По результатам теститрования на боевом сервере - ускоряемся. (v9)
-------------------
20230918 v10 Hаботает с реальными параметрами
20231005 v11 Надо наконец обслужить @IsTodayChanges,@SPType,@IsNotDuplicate,@ExpirationPeriod,@GenCurrentState
20231019 v12 Меняем обслуживание ошибок. Немного меняю политику работы с ЛПУ/Сетями (добавляю #lpu)
20231201 dbo Исправления видимости программ (#fh) + добавление нового параеметра с глубиной просмотра
			 Замена договоров: апдейтим весь старый догвор в LetterFlow
20231205 dbo Fork процедуры. Пусть останется на память.
			 Добавляем растягивание ошибки "нет договоров" на Полис - ТО-ЛПУ
20231211 dbo Прилично поменял смену договоров. Добавил загадочный кусок в цикл расчёта писем, который на лету подставляет 
			 новые договоры в старые письма. 
20231213 dbo Пришлось добавить поле флагов в LPULetterFlow - переделывал обслуживание повторной генерации писем, заодно 
			 часть флагов пойдёт на смену догововров и генерацию сверок
20231214 dbo Сделал форк от 20231214: полезных изменений много, а доработка смены договорв с флагами может всё порушить
			 Для памяти опишу побитно флаги в LPULetterFlow.LetterType:
			 0,1		- Копия LPULetter.IsNightly. Вроде как особо не нужен, но пусть будет
			 3 (&8)		- Письмо получено в результате запуска в режиме сверки @GenCurrentState
			 4 (&16)	- Письмо получено в результате перегенерации последних @IsNotDuplicate
			 5 (&32)	- В LPULetterFlow был заменён договор в процессе обнаружения "смены договора"
						  Тут надо не забыть подставлять старое значение из LPULetter при перегенрации.
20231215 dbo LPULetterKeyHash (UID для ключа полиса/сети/лпу/то лпу/ВД/аванса) и новая замена догововров. Надеюсь последняя.
20231216 dbo Косметика и шоколад.
20231217 dbo Вернул взад пофаканную функциональность обслуживания цепочек (@LetterCheckExisting)
*/
ALTER   proc [dbo].[prepareLPULettersByDate] 
	@ID_Session			uniqueidentifier = null output , -- ID для логов и, если будет добавлено поле, писем. Если не передают, сгенерю сам
	@LetterDate			datetime = null,			-- Наша любимая дата, которую можно не передавать - будет getdate()
	@ID_NightSession	uniqueidentifier = null,	-- ID для записи в письма и в старую статистику. !Для ночного запуска достаточно указать только этот параметр.
													-- Если передаётся, то всю фильтрацию и управляющие параметры игнорируем, а выбираем договора/полисы не КС, 
													-- изменённые неделю (две? месяц?) как. Все сетевые ЛПУ с флагом IsNightLetter
													-- и все ЛПУ с флагом IsNightLetter 
	-- Отладочное														
	@deletePrevLetters tinyint = null,				-- Если передали, то запуск тестовый и производится запись всякой моей статистики + в LPULetters записываются
													-- письма с пустым ID_LPUContract. Ну и ещё в паре мест проверяется для ускорения боевого запуска.
													-- (более не используется и =0) Если 1, то очищаем логи старых писем LPULEtterFlow_v3 по рассчитанным полисам
													-- Если 2, то режим почти боевой - ошибочные письма не генеряться, но лог производительности пишется

	-- Константы
	@ID_Responsible		uniqueidentifier = null,	-- ID_User. Для простановки в письмах и ошибках. Для NightSession: '0D0E06D3-7733-438B-8197-30FEB2BE66EF'
													-- Для ручного запуска обязательно
	@ID_Signing			uniqueidentifier = null,	-- Для простановки в письмах. Для NightSession: '5B61FCBD-2097-4DC9-BC32-4F471C9C885C'
	@ID_Branch			uniqueidentifier = null,	-- Фильтр договоров. Пишется в письмо. Если не передан, то в письмо запишем ЦО: '31DE0CD4-E579-44A6-B37B-D0E301B14F42'
	-- Фильтры
	-- Базовая фильтрация произойдёт в warp процедуре prepareLPULettersManual, но кое что придётся делать по ходу расчёта
	@AdvanceType		tinyint = null,				-- Факт(0)/Аванс(1). Применить к PriceListItems
	@TOLPURegion		tinyint = null,				-- Регионы(0)/Москва-и-Обл(1). По сути - фильтр LPUDepartment
						-- Датами я могу подрезать коробочные полисы, но с ДМС так лихо не прокатит. Их придётся фильтровать по ходу
						-- Опять же для ночного вызова будет проставляться @pEndDateFrom как @date-30
	@pStartDateFrom		datetime = null,			-- {RetailContractPolicy|ContractPolicy}.[Policy]StartDate. Для коробок - без франшизы!
	@pStartDateTo		datetime = null,			-- {RetailContractPolicy|ContractPolicy}.[Policy]StartDate. Поля округлять до даты!
	@pEndDateFrom		datetime = null,			-- isnull(ContractPolicy.PolicyEndDate,ContractPolicy.PlannedPolicyEndDate). К коробкам прменимо???
	@pEndDateTo			datetime = null,			-- isnull(ContractPolicy.PolicyEndDate,ContractPolicy.PlannedPolicyEndDate)
						-- Это добро тоже проще проверить при сборе программ
	@ID_Program			varchar(max) = null,		-- {RetailContractProgram|ContractPolicyPrograms}.ID; JSON [{"ID":"<guid>"}] или спискок guid+';'. Мне всё равно.
	@IsTodayChanges		tinyint = 0,				-- Исключение полисов с сегодняшними изменениями. 0 - не проверять, 1 - исключить сегодняшнее
	@ErrCorrections		varchar(max) = null,		-- Пересчёт по обработанным ошибкам: JSON типа {"ID":"LPULetterErrors.ID",...}  

	-- Параметры. 
	-- Управляют собственно генерацие писем. В ночном режиме игнорируются.
	@SPType				tinyint = null,				-- Письма с каким ImportType генерировать (0,1,2,4) 
	@IsNotDuplicate		int = null,					-- Повторять генрацию последних писем полисам (=1), если генерировать более нечего. 
													-- Замечу, что этот параметр используется в коде для исключения предыдущих писем из сравнения с текущим состоянием полисов/ВП.
													-- Т.е. 1 убирает результат последней генерации, 2 - двух последних и т.д. Хоть вообще всё.
													-- Сооответственно, если есть желание откзаться от результатов генерации писем за двое суток, то следует подать на вход 
													-- @IsNotDuplicate = 99999, @ExpirationPeriod = 2
													-- При этом будут проигнорированы все письма , посланные за последние два дня
	@ExpirationPeriod	int = null,					-- При указанном @IsNotDuplicate. Повторять генрацию последних писем полисам, если changedate > @date-@ExpirationPeriod
	@GenCurrentState	tinyint = null,				-- В рамках фильтра (@ID_LPU[Net] я бы требовал обязательно) сгенерировать письма-прикрепы по текущему состоянию БД, не глядя на ранее посланное. 
													-- Пока рабочий вариант выглядит как битовая маска: 1 - включает режим и посылает текущие активные полисы как прикрепы
													-- 2 - посылает прикрепы(открепы) также и на полисы, которые активируются (умрут) в будущем
													-- 4 - включает формироание открепов по умершим полисам, которые были активны ранее 
	@LetterDaysForward	int = 21,					-- за сколько дней до ближайшего события послыать письмо (макс). Т.е. про прикреп с 01/05 письмо будет послано не ранее 09/04.
	@LetterDayLimit		int = 3,					-- за сколько дней до "через одного(два,три...) события" посылать письмо. 
													-- Пример: прикрепили с завтрашнего дня полис, к программе, которая послепослезатвра изменится (мы это видим) - фомируем два письма (на замену и 
													--		на прикреп) в одну сессию.
													--		А если замена программы произойдёт через неделю, то пошлём письмо с заменой при следующем запуске генератора (в случае автомата - на 
													--		след день) или вообще за @dayLimit дней до события, если @checkExisting = 1
	@LetterCheckExisting tinyint = 1,				-- Не посылать письмо в будущее, если уже есть письмо про будущее:
													--	0: Проверять только "в будущие" письма, созданные в текущую сессию
													--	1: Проверять все письма, включая существующие на момент запуска
	@LetterDaysDetachBackward int = 30,				-- Глубина просмотра откреплённых программ назад
	@LetterCount		int = null OUTPUT,
	@ErrorCount			int = null OUTPUT

with recompile

	/*
		При старте процедуры в контексте соединения могут существовать таблицы, содержащие поле ID (и кластерный индекс по нему):
		• #Contracts		договора ДМС, для обсчёта (Contract.ID)
		• #RetailBoxes		коробочные договора (RetailContract.ID)
		• #PriceListItems	прайслисты (PriceListItems.ID)
		• #Polices			полисы ДМС, для обсчёта (ContractPolicy.ID)
		• #RetailPolices	коробочные полисы, для обсчёта (RetailContractPolicy.ID)

		Эти таблицы могут быть пустыми (значит берём всё) или вообще не существовать (тогда создаутся). 
		Остальная фильтрация по датам, программам, сегодняшним изменениям и пр. накладывается на подмножества объектов, определённые этими табличками
	*/
as
begin try
declare @debug tinyint = 0	-- открывает чуть ниже вызов prepareLPULettersDebug для заполнения табличек
/*
/*begin try--*/
--rollback tran

declare @ID_Session uniqueidentifier=null, @LetterDate datetime = null,@ID_NightSession	uniqueidentifier,
	@deletePrevLetters tinyint = null,@ID_Responsible uniqueidentifier,@ID_Signing uniqueidentifier, 
	@ID_Branch uniqueidentifier = '0D0E06D3-7733-438B-8197-30FEB2BE66EF', @TOLPURegion tinyint = null, @pStartDateFrom datetime = null,
	@pStartDateTo datetime = null,@pEndDateFrom datetime = null, @pEndDateTo	datetime = null, @ID_Program varchar(max) = null, @IsTodayChanges tinyint,-- = 0, 
	@SPType tinyint = null,	@IsNotDuplicate	tinyint = null,@ExpirationPeriod int = null, @GenCurrentState tinyint = null, @debug tinyint = 1,
	@LetterDaysForward int = 21, @LetterDayLimit int = 3, @LetterCheckExisting tinyint = 1, @LetterCount int = null, @ErrorCount int = null,
	@AdvanceType tinyint = null, @ErrCorrections varchar(max)=null, @LetterDaysDetachBackward int = 30

	set @ID_Responsible = 'BF6C4485-174B-4E9C-9F14-32B7DF8F26DD'
	set @ID_Signing = '5B61FCBD-2097-4DC9-BC32-4F471C9C885C'
	set @ID_Branch = '31DE0CD4-E579-44A6-B37B-D0E301B14F42'

--*/

declare @date datetime, @rc int, @objects2clean tinyint

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values (@ID_Session, 'Start: prepareLPULettersByDate', null, null) 

-- определяем таблицы параметров, для корректной компиляции и собственного удобства
if object_id('tempdb.dbo.#Contract')  is null		begin;	create table #Contract		 (ID uniqueidentifier null);	create clustered index parctr_idx	on #Contract	  (id);	end
if object_id('tempdb.dbo.#RetailBoxes') is null		begin;	create table #RetailBoxes	 (ID uniqueidentifier null);	create clustered index parrctr_idx	on #RetailBoxes	  (id);	end
if object_id('tempdb.dbo.#lpu')is null 				begin;	create table #lpu			 (ID uniqueidentifier null);	create clustered index parlpu_idx	on #lpu			  (id);	end
if object_id('tempdb.dbo.#Policies') is null 		begin;	create table #Policies		 (ID uniqueidentifier null);	create clustered index parpol_idx	on #Policies	  (id);	end
if object_id('tempdb.dbo.#RetailPolicies') is null 	begin;	create table #RetailPolicies (ID uniqueidentifier null);	create clustered index parrpol_idx	on #RetailPolicies(id);	end
-- в 12й версии она уже внутренняя, служебная
if object_id('tempdb.dbo.#PriceListItems')is null 	begin;	create table #PriceListItems (ID uniqueidentifier null);	create clustered index parpli_idx	on #PriceListItems(id);	end



/*
	В бою эта процедура вызывается из prepareLPULettersManual/Nightly, котороые готовят данные во вр.таблицах.
	Но для отладки наоборот вызываем prepareLPULettersdebug для их заполнения.
	Если кто-то сюда залез то надо просто поставить коммент "--" перед блоком, который хочется отлаживать, а
	предыдущий закомментить, убрав "--"
*/
if @debug = 1
begin
	
	/*
	set @deletePrevLetters  = 2 set @objects2clean=null  set @date = '20231021' declare @contr varchar(100) = 'Красный1910ОшибкиСФраншизой' --'Красный0310Ошибки'
	exec [dbo].[prepareLPULettersdebug] @date=@date, @ContractNumber = @contr, @deletePrevLetters = @deletePrevLetters, @dontRun=1, @objects2clean = @objects2clean, @ID_SessionInp  = @ID_Session output  --*/
	/*
	set @deletePrevLetters  = 0 set @date = '20230808' 
	exec [dbo].[prepareLPULettersdebug] @date=@date, @ContractNumber = 'Красный1010КСЬБеззамен', @deletePrevLetters = @deletePrevLetters, @dontRun=1, @ID_SessionInp  = @ID_Session output  --*/
	/*
	set @deletePrevLetters  = 1 set @date = '20230808' 
	exec [dbo].[prepareLPULettersdebug] @date=@date, @ContractNumber = 'Красный0310КС01', @deletePrevLetters = @deletePrevLetters, @dontRun=1, @ID_SessionInp  = @ID_Session output  --*/
	/*
	set @deletePrevLetters  = 0 set @objects2clean=3  set @date = '20230808' declare @contr varchar(100) = 'Красный1610Ошибки' --'Красный0310Ошибки'
	exec [dbo].[prepareLPULettersdebug] @date=@date, @ContractNumber = @contr, @deletePrevLetters = @deletePrevLetters, @dontRun=1, @objects2clean = @objects2clean, @ID_SessionInp  = @ID_Session output  --*/
	/*
	set @deletePrevLetters  = 2 set @objects2clean=3 set @date = '20230808' 
	exec [dbo].[prepareLPULettersdebug] @date=@date, @ContractNumber = 'Красный2409Грехипрошлого', @deletePrevLetters = @deletePrevLetters, @dontRun=1, @objects2clean = @objects2clean, @ID_SessionInp  = @ID_Session output  --*/
	/*
	set @deletePrevLetters  = 1 set @date = '20230808' 
	exec [dbo].[prepareLPULettersdebug] @date=@date, @ContractNumber = 'КрасныйПродление2707', @deletePrevLetters = @deletePrevLetters, @dontRun=1, @ID_SessionInp  = @ID_Session output  --*/
	/*
	set @deletePrevLetters  = 0 set @date = '20230808'
	exec [dbo].[prepareLPULettersdebug] @date=@date, @RetailContractNumber = '20230724-0001',  @deletePrevLetters = 2, @dontRun=1, @ID_SessionInp  = @ID_Session output --*/
	/*
	set @deletePrevLetters = 1 set @date = '20230808'
	exec [dbo].[prepareLPULettersdebug] @date=@date, @ContractNumber = 'Красный2907Сети01',  @deletePrevLetters = @deletePrevLetters, @LPUCode=null, @dontRun=1, @ID_SessionInp  = @ID_Session output--*/
	/*
	set @deletePrevLetters = 2 set @date = '20230808'
	exec [dbo].[prepareLPULettersdebug] @date=@date, @ContractNumber = 'Красный0208ПерекрытиеОткрепов',  @deletePrevLetters = @deletePrevLetters, @LPUCode=null, @dontRun=1, @ID_SessionInp  = @ID_Session output--*/
	/*
	set @deletePrevLetters = 2 set @date = '20230808'
	exec [dbo].[prepareLPULettersdebug] @date=@date, @ContractNumber = 'Красный2409ДвеПрограммы01',  @deletePrevLetters = @deletePrevLetters, @LPUCode=null, @dontRun=1, @ID_SessionInp  = @ID_Session output--*/
	/*
	set @deletePrevLetters = 2 set @date = '20230809'
	exec [dbo].[prepareLPULettersdebug] @date=@date, @contractNumber = 'Красный0208ЗаменасНачала91', @LPUCode=null, @objects2clean = 0, @dontRun=1, @ID_SessionInp  = @ID_Session output--*/
	/*
	set @deletePrevLetters = 2 set @date = '20231009'
	exec [dbo].[prepareLPULettersdebug] @date=@date, @contractNumber = 'Красный1010КССЗаменойсНачала', @LPUCode=null, @objects2clean = 0, @dontRun=1, @ID_SessionInp  = @ID_Session output--*/
	/*
	set @deletePrevLetters = 1 set @date = '20231017'
	exec [dbo].[prepareLPULettersdebug] @date=@date, @ContractNumber = null,  @deletePrevLetters = @deletePrevLetters, @LPUCode='207', @dontRun=1, @ID_SessionInp  = @ID_Session output--*/
	/*
	set @deletePrevLetters = 1 set @date = '20230808'
	exec [dbo].[prepareLPULettersdebug] @date=@date, @ContractNumber = 'Красный0310Подписи', @deletePrevLetters = @deletePrevLetters, @dontRun=1, @ID_SessionInp = @ID_Session output--*/
	/*
	set @deletePrevLetters = 2 set @date = '20230808'
	exec [dbo].[prepareLPULettersdebug] @date=@date, @ContractNumber = 'Красный0310ПодписиТехОперации', @deletePrevLetters = @deletePrevLetters, @dontRun=1, @ID_SessionInp = @ID_Session output--*/
	/*
	set @deletePrevLetters = 2 set @date = '20231010 10:00' set @IsNotDuplicate=1
	exec [dbo].[prepareLPULettersdebug] @date=@date, @ContractNumber = 'Красный0310ДвепрограммысФранш01', @deletePrevLetters = @deletePrevLetters, @dontRun=1,@IsNotDuplicate=1, @ID_SessionInp = @ID_Session output--*/
	/*
	set @deletePrevLetters = 2 set @date = '20230808'
	exec [dbo].[prepareLPULettersdebug] @date=@date, @ContractNumber = null, @policyNumber='77-МЮ-3861-21/0052-00620', @Lpucode='207', @deletePrevLetters = @deletePrevLetters, @retailcontractNumber='nothing', @dontRun=1, @ID_SessionInp = @ID_Session output--*/
	--/*
	set @deletePrevLetters = 0 set @date = getdate()
	set @LetterDaysForward = 5000 set @deletePrevLetters = 2 set @LetterDayLimit = 5000 set @LetterCheckExisting = 2
	--set @ID_Session=newid()
	exec dbo.prepareLPULettersManual @dontrun=1, @ID_Session=@ID_Session output,
       @ID_Responsible='BF6C4485-174B-4E9C-9F14-32B7DF8F26DD',
       @ID_Signing='5B61FCBD-2097-4DC9-BC32-4F471C9C885C',
       @ID_Branch    ='31DE0CD4-E579-44A6-B37B-D0E301B14F42',
       @ID_Contract  = 'FFEDB5BB-EFFA-4858-B99C-25C4659B6CD2',
       @ID_RetailContract = '00000000-0000-0000-0000-000000000000',
       @IsKS = 0
	   
	--*/
	/*
	set @deletePrevLetters = 2 set @date = getdate() --set @ErrCorrections = '[{"ID":"E24CAF22-2915-48B0-8A54-742B12684E8B"}]'
	select top 1 @ID_NightSession = id from NightServiceSession ns order by ns.CreateDateTime desc
	Exec prepareLPULettersManual
		@ID_Responsible='BF6C4485-174B-4E9C-9F14-32B7DF8F26DD',
		@ID_Signing='5B61FCBD-2097-4DC9-BC32-4F471C9C885C',
		@ID_Branch    ='31DE0CD4-E579-44A6-B37B-D0E301B14F42',
		@ID_lpu = '7B7C82C2-269C-4D15-8861-CCAA65AA956C'

		--@ErrCorrections = '[{"ID":"E24CAF22-2915-48B0-8A54-742B12684E8B"}]'
	--*/
	print 'debug mode'
end
/*
select * from  #Contract
select * from  #RetailBoxes	  
select * from  #PriceListItems
select * from  #Policies	  
select * from  #LPU
select * from  #RetailPolicies
*/
declare @call varchar(max) =
	'exec [dbo].[prepareLPULettersByDate] @LetterDate = '+isnull(''''+convert(varchar,@LetterDate,20)+'''','null')
	+ ',@ID_NightSession = '	+isnull(''''+convert(varchar(36),@ID_NightSession)+'''','null')
	+ ',@ID_Responsible = '		+isnull(''''+convert(varchar(36),@ID_Responsible)+'''','null')
	+ ',@ID_Signing = '			+isnull(''''+convert(varchar(36),@ID_Signing)+'''','null')
	+ ',@ErrCorrections = '		+isnull(''''+replace(@ErrCorrections,'''','''''')+'''','null')
	+ ',@ID_Branch = '			+isnull(''''+convert(varchar(36),@ID_Branch)+'''','null')
	+ ',@TOLPURegion = '		+isnull(     convert(varchar,@TOLPURegion),'null')
	+ ',@AdvanceType = '		+isnull(     convert(varchar,@AdvanceType),'null')
	+ ',@pStartDateFrom = '		+isnull(''''+convert(varchar,@pStartDateFrom,20)+'''','null')
	+ ',@pStartDateTo = '		+isnull(''''+convert(varchar,@pStartDateTo,20)+'''','null')
	+ ',@pEndDateFrom = '		+isnull(''''+convert(varchar,@pEndDateFrom,20)+'''','null')
	+ ',@pEndDateTo = '			+isnull(''''+convert(varchar,@pEndDateTo,20)+'''','null')
	+ ',@ID_Program = '			+isnull(''''+replace(@ID_Program,'''','''''')+'''','null')
	+ ',@IsTodayChanges = '		+isnull(     convert(varchar,@IsTodayChanges),'null')
	+ ',@SPType = '				+isnull(     convert(varchar,@SPType),'null')
	+ ',@IsNotDuplicate = '		+isnull(     convert(varchar,@IsNotDuplicate),'null')
	+ ',@ExpirationPeriod = '	+isnull(     convert(varchar,@ExpirationPeriod),'null')
	+ ',@GenCurrentState = '	+isnull(     convert(varchar,@GenCurrentState),'null')
	+ ',@LetterDaysForward = '	+isnull(     convert(varchar,@LetterDaysForward),'null')
	+ ',@deletePrevLetters = '	+isnull(     convert(varchar,@deletePrevLetters),'null')
	+ ',@LetterDayLimit = '		+isnull(     convert(varchar,@LetterDayLimit),'null')
	+ ',@LetterCheckExisting = '+isnull(     convert(varchar,@LetterCheckExisting),'null')
	+ ',@LetterDaysDetachBackward = '+isnull(convert(varchar,@LetterDaysDetachBackward),'null')
	
								

print convert(varchar,getdate(),108) + '	Запуск: [prepareLPULettersByDate] /' + convert(varchar,@deletePrevLetters)


-- проверка параметров
if (@ID_Responsible	is null or @ID_Signing is null) and @ID_NightSession is null
begin	
	raiserror('prepareLPULettersByDate_v12: параметры @ID_Responsible и @ID_Signing должны быть указаны при "ручном" запуске.',16,16)
	return
end
--select * from Users where id in ('BD694DE3-4F95-4A06-9EB3-848856B6F3FE','5B61FCBD-2097-4DC9-BC32-4F471C9C885C','BF6C4485-174B-4E9C-9F14-32B7DF8F26DD')



-- дефолты для ночного запуска
if @ID_Branch is null		set @ID_Branch		= '31DE0CD4-E579-44A6-B37B-D0E301B14F42'	-- ЦО
if @ID_Responsible is null	set @ID_Responsible = 'BF6C4485-174B-4E9C-9F14-32B7DF8F26DD'	-- автомат
if @ID_Signing is null		set @ID_Signing		= '5B61FCBD-2097-4DC9-BC32-4F471C9C885C'	-- автомат

--if @ID_Session is null		set @ID_Session		=  NEWID()

-- вчерашняя дата
if @LetterDate is null set @LetterDate = getdate() --convert(date,getdate()-1)
if @date is null set @date = @LetterDate

/*
-- программы формируем прямо тут из параметра @ID_Program
if object_id('tempdb.dbo.#Programs') is not null	
	drop table #Programs

create table #Programs (ID uniqueidentifier);	
create clustered index parpol_idx on #Programs(ID)

if @ID_Program is not null 
begin
	if ISJSON(@ID_Program)=1
		insert #Programs select convert(uniqueidentifier,json_value(value,'$.ID')) from openjson(@ID_Program)
	else
		insert #Programs select convert(uniqueidentifier,rtrim(ltrim(value))) from string_split(@ID_Program,';') where len(rtrim(ltrim(value)))=36
end		

-- если передали программы, то в полисах обеспечиваем все, привязанные к программе, а из контрактов убираем лишнее
if exists(select 1 from #programs)
begin
	delete c from #contract c where c.id not in (dbo.EmptyUID(null),null) and c.id not in (select ID_Contract from ContractProgram cp, #Programs p where cp.id = p.ID)
	delete p from #Policies p where p.id not in (dbo.EmptyUID(null),null) and p.id not in (select ID_ContractPolicy from ContractPolicyPrograms cp, #Programs p where cp.ID_ContractProgram = p.ID)
	if not exists(select id from #Policies where id_)
		insert #Policies select ID_ContractPolicy from ContractPolicyPrograms cp, #Programs p where cp.ID_ContractProgram = p.ID and not exists(select id from #Policies where id=ID_ContractPolicy) 
end
*/
-- если передан список исправленных ошибок, то загружаем его в #ErrCorrections

if object_id('tempdb.dbo.#ErrCorrections') is not null	
	drop table #ErrCorrections

create table #ErrCorrections (ID_ContractPolicy uniqueidentifier null, ID_LPU uniqueidentifier null, ID_LPUDepartment uniqueidentifier null, ID_LPUNet uniqueidentifier null, IsAdvance tinyint) 
create clustered index errcorr_idx on #ErrCorrections(ID_ContractPolicy, ID_LPU, ID_LPUDepartment, ID_LPUNet)

if @ErrCorrections is not null and isjson(@ErrCorrections)=1
begin
	--declare @ErrCorrections varchar(max) = '[{"ID":"E8E041F6-2518-4560-9EA4-BA7526CF82E3"}]'
	insert #ErrCorrections 
	select isnull(ID_ContractPolicy, rp.id) ID_ContractPolicy, dbo.EmptyUID(case when ID_LPUNet is null then ID_LPU end) ID_LPU, dbo.EmptyUID(ID_LPUDepartment) ID_LPUDepartment, dbo.EmptyUID(ID_LPUNet) ID_LPUNet, e.IsAdvance
	from LPULetterErrors  e
	join (select convert(uniqueidentifier,json_value(value,'$.ID')) ID from openjson(@ErrCorrections)) c on e.id_correction = c.id 
	left join RetailContractPolicy rp on rp.ID_RetailContract = e.ID_RetailContract
	group by isnull(ID_ContractPolicy, rp.id), ID_LPU, ID_LPUDepartment, ID_LPUNet,e.IsAdvance 	
--	select * from #ErrCorrections order by ID_LPUDepartment
	set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#ErrCorrections',@rc, null)

	delete #Policies
	delete #RetailPolicies
	delete #Contract
	delete #RetailBoxes
	delete #lpu

	--declare @ErrCorrections varchar(max) = '[{"ID":"E8E041F6-2518-4560-9EA4-BA7526CF82E3"}]'
	declare @find int = 0
	insert #Policies select distinct ID_ContractPolicy from LPULetterErrors err, ContractPolicy cp 
		where cp.id=ID_ContractPolicy and ID_Correction in (select convert(uniqueidentifier,json_value(value,'$.ID')) ID from openjson(@ErrCorrections)) union all select null
	set @find = @find + @@ROWCOUNT
	insert #RetailPolicies select distinct rcp.ID from LPULetterErrors err, RetailContractPolicy rcp 
		where rcp.ID_RetailContract=err.ID_RetailContract and ID_Correction in (select convert(uniqueidentifier,json_value(value,'$.ID')) ID from openjson(@ErrCorrections)) union all select null
	set @find = @find + @@ROWCOUNT
	insert #Contract select distinct ID_Contract from LPULetterErrors err 
		where ID_Contract is not null and ID_Correction in (select convert(uniqueidentifier,json_value(value,'$.ID')) ID from openjson(@ErrCorrections)) union all select null
	set @find = @find + @@ROWCOUNT
	insert #RetailBoxes select distinct ID_RetailContract from LPULetterErrors err 
		where ID_RetailContract is not null and ID_Correction in (select convert(uniqueidentifier,json_value(value,'$.ID')) ID from openjson(@ErrCorrections)) union all select null
	set @find = @find + @@ROWCOUNT
		
	insert #lpu select distinct id_lpu from LPULetterErrors err where ID_LPU is not null 
					and ID_Correction in (select convert(uniqueidentifier,json_value(value,'$.ID')) ID from openjson(@ErrCorrections)) 
				union all 
				select null 
				union all 
				select id_lpunet from LPULetterErrors err where ID_LPUNet is not null 
					and ID_Correction in (select convert(uniqueidentifier,json_value(value,'$.ID')) ID from openjson(@ErrCorrections))
	if @find = 0
	begin 
		raiserror('prepareLPULettersByDate_v12: по указанному набору исправлений (@ErrCorrection) не нашлось ничего для расчёта',16,16)
		return	
	end
end		

-- собираем прайслисты по переданным ЛПУ/Сетям или ошибкам
--declare @AdvanceType tinyint 
truncate table #PriceListItems

if not exists(select 1 from #ErrCorrections)
begin
--declare @AdvanceType tinyint 
	insert #PriceListItems select id from PriceListItems pli where (id_lpu in (select id from #lpu) or not exists(select id from #lpu))
			and (isnull(pli.IsPrepaid,0) = @AdvanceType or @AdvanceType is null)
			-- условия корректности ПЛ
			and case when ID_LPU is null then 0 else 1 end + case when ID_LPUDepartment is null then 0 else 2 end + case when ID_LPUNet is null then 0 else 4 end in (1,3,4)
	if exists(select 1 from #lpu)
	insert #PriceListItems select id from PriceListItems pli where (id_lpunet in (select id from #lpu) or not exists(select id from #lpu))
			and (isnull(pli.IsPrepaid,0) = @AdvanceType or @AdvanceType is null)
			-- условия корректности ПЛ
			and case when ID_LPU is null then 0 else 1 end + case when ID_LPUDepartment is null then 0 else 2 end + case when ID_LPUNet is null then 0 else 4 end in (1,3,4)
end
else
begin
	insert #PriceListItems select id from PriceListItems pli, #ErrCorrections e where pli.ID_LPU = e.ID_LPU
			and not exists(select 1 from #PriceListItems p where p.id=pli.ID)
			-- условия корректности ПЛ
			and case when pli.ID_LPU is null then 0 else 1 end + case when pli.ID_LPUDepartment is null then 0 else 2 end + case when pli.ID_LPUNet is null then 0 else 4 end in (1,3,4)

	insert #PriceListItems select id from PriceListItems pli, #ErrCorrections e where pli.ID_LPUNet = e.ID_LPUNet
			and not exists(select 1 from #PriceListItems p where p.id=pli.ID)
			-- условия корректности ПЛ
			and case when pli.ID_LPU is null then 0 else 1 end + case when pli.ID_LPUDepartment is null then 0 else 2 end + case when pli.ID_LPUNet is null then 0 else 4 end in (1,3,4)
end

-- С датами немного мухлюем:
-- во первых меняем верхние границы на yyyy.mm.dd 23:59:59
set @pEndDateTo		= dateadd(second,-1,convert(datetime,convert(date,@pEndDateTo+1)))
set @pStartDateTo	= dateadd(second,-1,convert(datetime,convert(date,@pStartDateTo+1)))
-- во вторых заменяем nullы на "бесконечные" периоды
if @pStartDateFrom	is null set @pStartDateFrom	= '20000202'	-- от глубин
if @pStartDateTo	is null set @pStartDateTo	= '21200212'	-- до светлого будущего
if @pEndDateFrom	is null set @pEndDateFrom	= convert(date,@date-30)	-- если нам не говорят дату явно, то рассматриваем полисы, умершие не раньше месяца как
if @pEndDateTo		is null set @pEndDateTo		= '21200212'	-- до светлого будущего

print convert(varchar,getdate(),108) + '	Собрали все страховые программы'

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session,'prepareLPULettersByDate',null,@call)


if object_id('tempdb.dbo.#PoliciesExcept')!=0 
	drop table #PoliciesExcept
create table #PoliciesExcept  (id uniqueidentifier)
declare @polDate datetime = convert(date, getdate())

if isnull(@IsTodayChanges,0)=1
begin
	insert #PoliciesExcept 
	select id from (
		select id_contractpolicy id from ContractPolicyPrograms where StartDate >= @polDate or EndDate >= @polDate 
		union
		select id_contractpolicy from ContractPolicyElementsKSDirectAccess ks, ContractPolicyPrograms pp where ks.id_contractpolicyprogram = pp.id and ks.ChangeDate >= @polDate
		union
		select id_contractpolicy from ContractPolicyFranchiseStatusHistory where StartDate >= @polDate
		union
		select id_contractpolicy from ContractProgramElementsFranchiseInterestHistory feh, ContractProgramElements pe, ContractPolicyPrograms pp where pp.ID_ContractProgram=pe.ID_ContractProgram and pe.id=feh.ID_ContractProgramElement 
							and (feh.CreateDate >= @polDate or pe.FranchiseChangeDate >= @polDate)
		--union select id_contractpolicy  from ContractAddNullification np, ContractPolicyPrograms pp where pp.ID_ContractProgram=np.ID_ContractProgram and NullifyDate >= @polDate
		union
		select id from ContractPolicy where ID_SubjectP in (select id from SubjectP s where ChangeDateForLetter  >= @polDate))p
	where (id in (select p.id from #Contract c, ContractPolicy p where p.ID_Contract=c.id) or not exists(select id from #Contract)) 

	insert #PoliciesExcept 
	select id from RetailContract where UpdatedWhen >= @polDate
end

create clustered index PoliciesExcept_idx on #PoliciesExcept (id)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) 
		values(@ID_Session, 'prepareLPULettersByDate', null, convert(varchar,@date,20)+'#Contract: '+convert(varchar,(select count(distinct dbo.nullUID(id)) from #Contract))+
		'; #LPU: '+convert(varchar,(select count(distinct dbo.nullUID(id)) from #LPU))+
		'; #RetailBoxes: '+convert(varchar,(select count(distinct dbo.nullUID(id)) from #RetailBoxes))+'; #PriceListItems: '+convert(varchar,(select count(distinct dbo.nullUID(id)) from #PriceListItems))+
		'; #Policies: '+convert(varchar,(select count(distinct dbo.nullUID(id)) from #Policies))+'; #RetailPolicies: '+convert(varchar,(select count(distinct dbo.nullUID(id)) from #RetailPolicies))+
		'; #PoliciesExcept: '+convert(varchar,(select count(distinct dbo.nullUID(id)) from #PoliciesExcept))+'; #ErrCorrections: '+convert(varchar,(select count(*) from #ErrCorrections)))
		
/*
print @pStartDateFrom	
print @pStartDateTo		
print @pEndDateFrom		
print @pEndDateTo		

*/

-------------------------------------------------------------------------------
-- Обработка периодов активности программ/элментов на полисах
-------------------------------------------------------------------------------

-- сначала собираем историю франшизанутости программ в виде договор-полис-программа-элемент-дата-дата, т.е. периоды, в котороые франшизу вообще надо считать
--declare @pEndDateFrom datetime = '20230926'

if object_id('tempdb.dbo.#cp')!=0 
	drop table #cp

select cp.*, cd.id id_contractdetail, isnull(cdLast.FranchiseBlockLevel,0) FranchiseBlockLevel 
into #cp
FROM ( --declare @pEndDateFrom datetime = '20230911'
	select cp.id, cp.ID_Contract, cp.id_contractadd, convert(date,cp.startdate) startdate, convert(date,cp.EndDate) Enddate, convert(date, can.NullifyDate) nulProgDate
	from ContractProgram cp 
	left join ContractAddNullification can 
			join ContractAdd na on na.id=can.ID_ContractAdd 	
			join ContractDetail nd on nd.ID_ContractAdd = na.id and nd.SigningStatus>=30	-- подписано ли?
		on can.ID_ContractProgram=cp.id
	where (cp.ID_Contract in (select ID from #Contract) or not exists(select ID from #Contract)) and cp.EndDate > @pEndDateFrom
		and (cp.id in (select distinct ID_ContractProgram from ContractPolicyPrograms cpp, #Policies p where p.id=cpp.ID_ContractPolicy) or not exists(select 1 from #Policies where id is not null and id != dbo.EmptyUID(null)))
) cp
join Contract c on c.id=cp.ID_Contract
join ContractDetail cd on cd.ID_Contract=cp.ID_Contract and cd.ID_ContractAdd is null and cd.SigningStatus >= 30 -- контракт подсипан?
join ContractDetail cdLast on cdLast.ID=c.ID_LastContractDetail

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#cp',(select count(*) from #cp), null)

create clustered index cprog_idx on #cp (id)

if exists(select 1 from #Contract where id not in(dbo.EmptyUID(null), null))
	if not exists(select 1 from #cp)
		begin 
			raiserror('prepareLPULettersByDate: Не нашли действующих подписанных договоров!',16,16)
			return
		end 
	else
		delete #Policies from ContractPolicy cp where #Policies.id=cp.id and ID_Contract not in (select id from #Contract)

--select * from #cp
--select * from #Contract


if object_id('tempdb.dbo.#fh')!=0 
	drop table #fh
	
-- собираем все элементы, укаазываем признак франшизности, если есть. Туда же валим периоды работы франшыз, и полисы.
/* 
	Тут идея следующая: для каждого полиса-программы-элеметна собрать периоды когда программа действует. 
	Для нефраншизных программ всё просто: они начинаются в AttachDate, а заканчиваются в DetachDate.
	С франшизными программами (элементами) и КС посложнее: 
	• первые могут несколько раз включаться-выключаться историей франшиз
	• вторые далают то же самое с помощбю таблицы ...KSDirectAccess

	Соответственно, ниженаписанный запрос собирает элементы-полисы с периодом их активности (обычные прораммы), умножает
	полученное на KSDirectAccess (возможно ограничение периода или увеличение кол-ва пеииодов для договоров КС), и полученное 
	множество умножается на истрию франшиз (возможно ограничение периодов или увеличение кол-ва пеииодов для франшизных
	элементов).

	Т.е. для полиса-элемента-программы длительностью три года мы получим одну запись с ksStart-ksEnd длиной в три года (если
	полис сразу подключили и он живёт до конца). Если в KSDiectAccess есть пара записей в эти три года, то для элемента в табличку 
	#fh записшется два записи с периодам из KSDiectAccess, ограниченными трехлетним исходным периодм.
	Если в истории франщиз есть семь периодов, то кол-во записей может возрасти до восьми.

	В этом же запросе проверяем подписанность ДС для аттачей-детачей.

	Обработка флага франшизности программы (FranchiseBlockLevel) происходит после получения первоначальной выборки доступных 
	периодов.
*/

--declare @date datetime = '20230808'
declare @ID_AKDirect uniqueidentifier = (select top 1 ID from LPUAccessKinds where KindType = 4), @BackDate datetime = getdate()-@LetterDaysDetachBackward

select 1 src, cpp.ID_ContractPolicy, cpp.ID_Contract, cpp.id_contractdetail, cpp.ID_ContractProgramElement, cpp.ID_ContractProgram, cpp.ID_ContractPolicyPrograms, cpp.ID_PriceListItem, ID_LPUAccessKind,ID_ContractProgramElementKS,
	FranchiseBlockLevel, progStart, progEnd, 
	case when isnull(fh.startdate,ksStart)>ksstart then fh.startdate else ksstart end StartDate,	-- 20230903 Ускорение: это я забыл и апдейчу пустую startDate в конце. Плохо.
	isnull(fh.EndDate, ksend) enddate, --(select max(a) from (values(fh.startdate),(ksStart)) as a(a)) startDate, (select min(a) from (values(fh.EndDate),(ksEnd)) as a(a)) endDate, -- потом поправим
	ksStart, 
	--ksEnd,/*			-- 20231115 Вообще странное место. Непонятно как я его забыл
	case when ksEnd>isnull(fh.EndDate, ksend) then isnull(fh.EndDate, ksend) else ksEnd end ksend, --*/
	FranchiseInterest
into #fh --declare @date datetime = '20230808'; select *
from (--declare @date datetime = '20230808';
	SELECT cpol.ID ID_ContractPolicy, cp.ID_Contract, cp.id_contractdetail, cpe.id ID_ContractProgramElement, cpe.ID_ContractProgram, cpp.id ID_ContractPolicyPrograms, cpe.ID_PriceListItem, 
			case when la.KindType in (4,50) then la.ID else @ID_AKDirect end ID_LPUAccessKind, -- для договоров КС, где АК может оказаться "через пультом", ставим "прямой доступ"
			ks.ID ID_ContractProgramElementKS,
			isnull(cp.FranchiseBlockLevel,0) FranchiseBlockLevel, 
			convert(datetime,convert(date,(select max(a) from (values(cpp.AttachDate),(cp.StartDate)) as a(a)))) progStart, 
			cp.EndDate progEnd, --convert(datetime,convert(date,(select min(a) from (values(cpp.DetachDate),(cp.EndDate)) as a(a)))) progEnd,
			convert(datetime,convert(date,(select max(a) from (values(cpp.AttachDate),(ks.AttachDate),(cp.StartDate)) as a(a)))) ksStart, 
			convert(datetime,convert(date,(select min(a) from (values(case when cdd.id is null then cp.EndDate else cpp.DetachDate end), -- если детач не подписан, то конец программы
															(ks.DetachDate),(cp.EndDate),(cp.nulProgDate)) as a(a)))) ksEnd
		--	, ks.AttachDate, ks.DetachDate, cpp.AttachDate, cpp.DetachDate, cp.EndDate, cp.StartDate
		--declare @date datetime = getdate(); select cp.*,cpol.*
		FROM #cp cp

		join ContractPolicy cpol on cpol.ID_Contract = cp.ID_Contract and (cpol.ID in (select ID from #Policies) or not exists((select ID from #Policies))) 
					--/*
					and	cpol.PolicyStartDate between @pStartDateFrom and @pStartDateTo
					and cpol.PlannedPolicyEndDate between @pEndDateFrom and @pEndDateTo
					and (cpol.PolicyEndDate is null or cpol.PolicyEndDate >= @pEndDateFrom)
					--*/
					-- вот так правильнее исключать "сегодняшние" полисы
					--and (isnull(@IsTodayChanges,0) = 0 or cpol.LastChangeDate < convert(date, getdate()))
					and cpol.id not in (select id from #PoliciesExcept)
		join ContractPolicyPrograms cpp on ID_ContractProgram=cp.id and ID_ContractPolicy=cpol.id --and AttachDate<=DetachDate 
					-- 20231202 Тут очень тонкий момент! Просматривать будем текущие программы (до 30 дней вглубь), даже если от них открепились в глубокой древности;
					--			Открепы не старше 30 дней (по умолчанию); И более старые открепы, физически сделанные до 30 дней как
					--			Понятно, что 30 дней - это дефолт. Пердать в параметрах можно хоть столет назад
					and (DetachDate >= @BackDate or cpp.Enddate>= @BackDate or isnull(cp.nulProgDate,cp.Enddate)>=@BackDate)
					--and (cpp.ID_ContractProgram in (select ID from #Programs) or not exists(select ID from #Programs))

		join ContractDetail cda on cda.ID_Contract=cp.ID_Contract and cda.id=cpp.ID_AttachDetail and cda.SigningStatus >= 30 -- аттач подписан?
		left join ContractDetail cdd on cdd.ID_Contract=cp.ID_Contract and cdd.id=cpp.ID_DetachDetail and cdd.SigningStatus >= 30 -- детач подписан?

		join ContractProgramElements cpe on cp.id=cpe.ID_ContractProgram and (cpe.ID_PriceListItem in (select ID from #PriceListItems) or not exists(select ID from #PriceListItems))
		--join PriceListItems pli on pli.id=cpe.ID_PriceListItem --and id_lpu='1209D56E-B698-4879-874C-5891948F82EE'
		join LPUAccessKinds la on la.id=cpe.ID_LPUAccessKind

		-- Это смешной кусок, призванный заткнуть дырку при которой замена программы в КС превращалась в откреп, -->
		-- т.к. изменения ContractPolicyElementsKSDirectAccess.DetachDate делаются до подписаняия ДС на замену и 
		-- завершают прямой доступ загодя
		--left join ContractPolicyElementsKSDirectAccess ks /*			-- убрать коммент в начале строки для переключения на старое
		left join (select id, isnull(newDetach,DetachDate) DetachDate, AttachDate, ID_ContractPolicyProgram, ID_ContractProgramElement
				from ContractPolicyElementsKSDirectAccess ksda
				outer apply (select max(cdd.PlannedEndDate) newDetach from ContractPolicyPrograms cpd 
								join ContractDetail cdd 
									on cdd.id=cpd.ID_DetachDetail-- and cdd.ID_Contract='7EBB1C81-16E5-48B3-9D90-5DA7721C0E57'
										and cdd.SigningStatus<30 
								join ContractPolicyPrograms cpa 
									on cpa.ID_ContractPolicy=cpd.ID_ContractPolicy and cpa.AttachDate=cpd.DetachDate+1 and cpd.ID_DetachDetail=cpa.ID_AttachDetail
								where cpd.ID = ksda.ID_ContractPolicyProgram and ksda.DetachDate=cpd.DetachDate having max(cdd.PlannedEndDate) is not null) nsDet) ks --*/
		-- Это смешной кусок, призванный заткнуть дырку при которой замена программы в КС превращалась в откреп, <--
			on ks.ID_ContractPolicyProgram=cpp.id and ks.ID_ContractProgramElement=cpe.id 
				--and (ks.AttachDate<=ks.DetachDate or ks.DetachDate is null)			--20231113 Мухин: это тонкий момент, работающий аналогично отключенной проверке в CPP. Нам крофь из носу надо засветить полись в #fh
				and ((ks.AttachDate <= cpp.DetachDate and (ks.DetachDate >= cpp.AttachDate or ks.DetachDate is null)) 
					or (ks.AttachDate=cpp.AttachDate and ks.DetachDate=cpp.DetachDate)) --20231113 Мухин: а возникает вся эта блевостика, когда CpeKSDA аннулируют вместе с CPP
		where ks.id is not null or la.KindType in (4,50)
	) cpp
left join (select ID_ContractProgramElement, convert(datetime,convert(date,startdate)) startdate, convert(datetime,convert(date,EndDate)) EndDate, FranchiseInterest 
			from ContractProgramElementsFranchiseInterestHistory 
			where (EndDate is null or convert(date,startdate) < convert(date,EndDate)) and FranchiseInterest > 0
		) fh on cpp.ID_ContractProgramElement=fh.ID_ContractProgramElement 
			and (fh.StartDate between cpp.ksStart and cpp.ksEnd or isnull(fh.EndDate, cpp.ksEnd) between cpp.ksStart and cpp.ksEnd 
			or cpp.ksStart between fh.StartDate and isnull(fh.EndDate, cpp.ksEnd) or cpp.ksEnd between fh.StartDate and isnull(fh.EndDate, cpp.ksEnd))
--where (isnull(@deletePrevLetters,2) != 2  or ksEnd >= convert(date,@date)) -- Это призвано обрезать всё отжившее свой срок. В режиме отладки старое оставляет для красоты диаграмм

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#fh', (select count(*) from #fh), null)


 
-- контроль расподписанности -->
/*
С 23 июня на проде есть поле UnSigningOperationDate в СontractDetail  - дата последнего расподписания договора 
ДС (СП) – там уже 350 деталей договоров или ДС (СП) где снимали хрть раз подпись по состоянию на прошдые выходные 
15 из них фактически расподписаны.
Это значит что если в соответствующем ContractDetail SigningStatus < 30 и UnSigningOperationDate is not null 
договор или ДС(СП) расподписаны – снята подпись.
Сответственно достаточно проверить что по полису
1.	В договоре снята подпись или
2.	Хотя бы у одном ID_AttachDetail или ID_DetachDetail снята подпись 
Если такое имеет место быть можно полис исключать из анализа писем и соответственно генерации
*/
if object_id('tempdb.dbo.#unsignedPol')!=0
	drop table #unsignedPol

select cp.ID into #unsignedPol from (select ID_ContractPolicy from #fh group by ID_ContractPolicy) cf, ContractPolicy cp 
			where cf.ID_ContractPolicy=cp.ID and 
				(--exists(select 1 from ContractDetail d where d.ID_ContractAdd=cp.ID_ContractAdd and d.UnSigningOperationDate is not null and SigningStatus<30)
				   exists(select 1 from ContractPolicyPrograms cpp, ContractDetail d where cpp.ID_ContractPolicy=cp.id and d.ID=cpp.ID_AttachDetail and d.UnSigningOperationDate is not null and SigningStatus<30 and cpp.DetachDate>=convert(date,@date))
				or exists(select 1 from ContractPolicyPrograms cpp, ContractDetail d where cpp.ID_ContractPolicy=cp.id and d.ID=cpp.ID_DetachDetail and d.UnSigningOperationDate is not null and SigningStatus<30 and cpp.DetachDate>=convert(date,@date)))
create clustered index unsignedPol_Idx on #unsignedPol(ID)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#unsignedPol', (select count(*) from #unsignedPol), null)

delete fh from #fh fh where ID_ContractPolicy in (select ID from #unsignedPol)


-- в принципе, тут можно сохранить удалённый набор и потом вставить его в LPULetterErrors

-- контроль расподписанности <--

if object_id('tempdb.dbo.#cp')!=0 and @deletePrevLetters is null
	drop table #cp

--

print getdate()

create clustered index fhist_idx on #fh (ID_Contract, ID_PriceListItem, ID_ContractPolicy, ksstart, ksend)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#fh index', null, null)

print getdate()

--select * from #fh order by id_contractpolicy, ksstart,ID_ContractProgramElement


if object_id('tempdb.dbo.#pn')!=0 
	drop table #pn

-- исходно франшизные элеметы по котороым надо растянуть блокировку сливаем в отдельную табличку. Программа может входить в ключ блокировки, если сделают значение отличное от 0 и 1
-- в качестве даты начала периода берём дату первой блокировки полиса (можно дату подтверждения франшизы - пофиг)
-- Цель: получить периоды, начиная с подтверждения франшизы (или первой блокировки), в которые должны блокироваться все элементы
select fh.ID_ContractPolicy, fh.ID_Contract, case fh.FranchiseBlockLevel when 1 then dbo.EmptyUID(null) else fh.ID_ContractProgram end ID_ContractProgram, 
	1 fi, case when fh.startDate<blckStart then blckStart else fh.startDate end StartDate, fh.EndDate, startdate s1, blckStart,
	identity(int,0,1) id
into #pn
from #fh fh 
join (select ID_ContractPolicy, convert(date,min(startdate)) blckStart from ContractPolicyFranchiseStatusHistory where FranchiseStatus=2 group by ID_ContractPolicy) cd on cd.ID_ContractPolicy=fh.ID_ContractPolicy 
			and fh.EndDate>=blckStart 
where fh.FranchiseBlockLevel=1 and fh.FranchiseInterest > 0

create clustered index pnist_idx on #pn (ID_ContractPolicy, ID_Contract, ID_ContractProgram, startdate, enddate)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#pn',(select count(*) from #pn), null)

--select * from #fh
--select * from #pn

-- максимально раздвигаем пересекающиеся периоды существующих франшизных элементов
declare @fhStep int = 0, @fhRows int
while 1=1
begin
	set @fhstep = @fhstep + 1
	-- удаляем дубли
	delete #pn from (select max(id) d, ID_Contract c, ID_ContractPolicy p, ID_ContractProgram g, startdate s, enddate e from #pn group by ID_Contract, ID_ContractPolicy, ID_ContractProgram, startdate, enddate) d
	where ID_Contract=c and ID_ContractPolicy=p and ID_ContractProgram=g and startdate=s and enddate=e and id!=d

	update p set StartDate=s, EndDate=e 
	from #pn p,(select p1.ID_Contract c, p1.ID_ContractPolicy p, p1.ID_ContractProgram g, min(case when p1.StartDate<p2.StartDate then p1.StartDate else p2.StartDate end) s, max(case when p1.EndDate<p2.EndDate then p1.EndDate else p2.EndDate end) e
				from #pn p1, #pn p2 where p1.ID_ContractPolicy=p2.ID_ContractPolicy and p1.ID_Contract=p2.ID_Contract and p1.ID_ContractProgram=p2.ID_ContractProgram 
					and (p1.StartDate between p2.StartDate and p2.EndDate or p1.EndDate between p2.StartDate and p2.EndDate or p2.StartDate between p1.StartDate and p1.EndDate or p2.EndDate between p1.StartDate and p1.EndDate)
				group by p1.ID_Contract, p1.ID_ContractPolicy, p1.ID_ContractProgram) n
	where p.ID_ContractPolicy=p and p.ID_Contract=c and p.ID_ContractProgram=g and (StartDate!=s or EndDate!=e)

	set @fhRows = @@ROWCOUNT
	if @fhRows=0 break

	set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#fh step '+convert(varchar,@fhrows),@fhRows, null)
end

print getdate()

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#fh last step', null, null)


-- теперь в #pn лежат все периоды, в которы договор (программа) должна блокироваться полностью

-- у франшизных элементов рсширяем (но не сужаем) дату конца, если они попали в новые периоды
update f set EndDate=p.EndDate--select * 
from #fh f, #pn p where  p.ID_ContractPolicy=f.ID_ContractPolicy and p.ID_Contract=f.ID_Contract
	and (p.ID_ContractProgram=f.ID_ContractProgram or p.ID_ContractProgram=dbo.EmptyUID(null)) and f.FranchiseInterest > 0
	and f.EndDate>=p.StartDate and f.EndDate < p.EndDate and f.startDate<=p.EndDate
	and (p.StartDate between f.ksStart and f.ksEnd or p.StartDate between f.ksStart and f.ksEnd or f.ksStart between p.StartDate and p.EndDate or f.ksEnd between p.StartDate and p.EndDate)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#fh EndDate', @rc, null) waitfor delay '00:00:00.002'

-- у франшизных элементов рсширяем (но не сужаем) дату начала, если они попали в новые периоды
update f set StartDate=p.StartDate--select * 
from #fh f, #pn p where  p.ID_ContractPolicy=f.ID_ContractPolicy and p.ID_Contract=f.ID_Contract
	and (p.ID_ContractProgram=f.ID_ContractProgram or p.ID_ContractProgram=dbo.EmptyUID(null)) and f.FranchiseInterest > 0
	and f.startDate > p.StartDate and f.startDate<=p.EndDate and f.EndDate>=p.EndDate
	and (p.StartDate between f.ksStart and f.ksEnd or p.StartDate between f.ksStart and f.ksEnd or f.ksStart between p.StartDate and p.EndDate or f.ksEnd between p.StartDate and p.EndDate)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#fh StartDate', @rc, null)

-- все нефраншизные программы, которые надо офраншизить в новые периоды заливаем в #fh
-- также заливаем и для франшизных, если их периоды активноости франшизы не попали в #pn
--select src, FranchiseInterest, ID_ContractPolicy, ID_ContractProgramElement, startdate, enddate, ksStart, ksEnd, progStart, progEnd from #fh order by ID_ContractPolicy, ID_ContractProgramElement, startdate


insert #fh (src, ID_ContractPolicy, ID_Contract, id_contractdetail, ID_ContractPolicyPrograms,ID_ContractProgramElement, ID_ContractProgram, ID_PriceListItem, ID_LPUAccessKind,
	 f.progStart, f.progEnd, p.StartDate,p.EndDate, FranchiseBlockLevel, FranchiseInterest, ksStart, ksEnd)
select 0, f.ID_ContractPolicy, f.ID_Contract, f.id_contractdetail, f.ID_ContractPolicyPrograms, f.ID_ContractProgramElement, f.ID_ContractProgram, f.ID_PriceListItem, f.ID_LPUAccessKind,
	 progStart, progEnd, case when p.StartDate<f.ksStart then f.ksStart else p.StartDate end, case when p.EndDate>f.ksEnd then f.ksEnd else p.EndDate end, f.FranchiseBlockLevel, 1 FranchiseInterest, 
	 f.ksStart, f.ksEnd
from #fh f, #pn p where  p.ID_ContractPolicy=f.ID_ContractPolicy and p.ID_Contract=f.ID_Contract and (p.ID_ContractProgram=f.ID_ContractProgram or p.ID_ContractProgram=dbo.EmptyUID(null)) 
	and (f.FranchiseInterest is null or not (p.StartDate between f.StartDate and f.EndDate or p.StartDate between f.StartDate and f.EndDate or f.StartDate between p.StartDate and p.EndDate or f.EndDate between p.StartDate and p.EndDate))
	and (p.StartDate between f.ksStart and f.ksEnd or p.StartDate between f.ksStart and f.ksEnd or f.ksStart between p.StartDate and p.EndDate or f.ksEnd between p.StartDate and p.EndDate)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#fh add periods', @rc, null)

--select src, FranchiseInterest, ID_ContractPolicy, ID_ContractProgramElement, startdate, enddate, ksStart, ksEnd, progStart, progEnd from #fh order by ID_ContractPolicy, ID_ContractProgramElement, startdate

-- удаляем исходные записи нефраншизных программ - для них только что созданы дубли по колву периодов полной блокировки
-- а вот свежесозданные дополнения к франшизным программам оставляем

delete d --select * 
from #fh d where FranchiseInterest is null and src=1 and exists(select 1 from #fh n where n.src=0 and n.ID_ContractPolicy=d.ID_ContractPolicy and d.ID_ContractProgramElement=d.ID_ContractProgramElement)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#fh delete old periods', @rc, null)

update #fh set startDate=ksStart --select count(*) from #fh -- 20230903 Ускорение: этот оператор после изменений выше займёт скунд 10, т.к. апдейтить нечего, но пусть будет
where startDate is null or startDate < ksStart

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#fh correct startDate', @rc, null)

/* 20230903 Ускорение: это нам особо не нужно - будем грузить в #pe поставим inull
update #fh set FranchiseInterest=0 --select count(*) from #fh
where FranchiseInterest is null 
*/
update f set ksEnd=p.startdate-1 --select *
from #fh f
cross apply (select top 1 startdate from #fh p where f.ID_ContractPolicy=p.ID_ContractPolicy and f.ID_ContractProgramElement=p.ID_ContractProgramElement and f.startdate<p.startdate order by p.startdate) p
where ksEnd!=p.startdate-1

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#fh correct ksEnd', @rc, null)

update f set ksStart=p.ksend+1 --select *
from #fh f
cross apply (select top 1 ksend from #fh p where f.ID_ContractPolicy=p.ID_ContractPolicy and f.ID_ContractProgramElement=p.ID_ContractProgramElement and f.startdate>p.startdate order by p.startdate) p
where ksStart!=p.ksend+1

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#fh correct ksStart', @rc, null)

print getdate()

declare @cnt int
select @cnt = count(*) from #fh
print convert(varchar,getdate(),108) + '	Обработка периодов активности программ/элментов на полисах ' + convert(varchar,@cnt)

if object_id('tempdb.dbo.#pn')!=0 and @deletePrevLetters is null
	drop table #pn

--select * from #fh
--declare @date datetime = '20230808'
insert #fh (src,ID_ContractPolicy,ID_Contract,id_contractdetail,ID_ContractProgramElement,ID_ContractProgram,ID_ContractPolicyPrograms,
	ID_PriceListItem,ID_LPUAccessKind,FranchiseBlockLevel,
	progStart,progEnd,startdate,enddate,ksStart,ksEnd,FranchiseInterest)
select --declare @date datetime = '20230808'; select IsActive,Enddate,startdate,
	10, ID_ContractPolicy, id_contract, dbo.EmptyUID(null) id_contractdetail, ID_CPE, ID_ContractProgram, dbo.EmptyUID(null) ID_ContractPolicyPrograms,
	ID_PriceListItem,ID_LPUAccessKind,0,
	StartDate, endPln, StartDate, Enddate, StartDate, Enddate, 1-isactive
from (--declare @date datetime = '20230808'
	select rc.StartDate+isnull(rcpr.FranchisePeriod,0) StartDate, 
			case when  rc.StartDate+isnull(rcpr.FranchisePeriod,0) <= rc.enddate then rc.enddate else rc.StartDate+isnull(rcpr.FranchisePeriod,0) end Enddate, -- даже не зажившему полису даём пожить денёк - вдруг нужен откреп
		-- этот флажок попользуем для якобы неактивной франшизы, т.е. с точки зрения последующих алгоритмов полис какбе был, но так и не активировался
		case when rc.StartDate+isnull(rcpr.FranchisePeriod,0) > rc.EndDate or rc.enddate<convert(date,@date) then 0 else 1 end IsActive, 
		-- если не было фокусов с отменой страховки, плановая дата конца равна дате конца, иначе задвигаем её подальше, чтобы дальнейшие алгоритмы сформировали откреп
		case when rc.StartDate+isnull(rcpr.FranchisePeriod,0) > rc.EndDate or isnull(isNullify,0)=1 then rc.endDate+20+isnull(rcpr.FranchisePeriod,0) else rc.EndDate end endPln,  
		isnull(rc.IsNullify,0) IsNullify, rc.id ID_RContract, rpol.ID ID_RPolicy, rc.ContractNumber, rcpr.ProgramName, rc.SigningDate,
		rpol.id ID_ContractPolicy, rcpr.id ID_ContractProgram, cpe.id ID_CPE, 1 IsFranchise, ID_PriceListItem,ID_LPUAccessKind,
		rc.id id_contract
	from RetailContract rc, RetailContractPolicy rpol, RetailContractProgram rcpr, RetailContractProgramElement cpe, LPUAccessKinds la
	where (rc.ID in (select ID from #RetailBoxes) or not exists(select ID from #RetailBoxes))
		and rc.SigningStatus>=30 -- Контроль "расподписанности" тут вообще не нужен: подписан - считаем, не подписан - не считаем
		and rc.id=rpol.ID_RetailContract and rc.ID_RetailContractTemplate = rcpr.ID_RetailContractTemplate
		and rc.EndDate between @pEndDateFrom and @pEndDateTo
		and cpe.ID_RetailContractProgram=rcpr.ID 
		and la.id=cpe.ID_LPUAccessKind and KindType in (4,50) 
		and (cpe.ID_PriceListItem in (select ID from #PriceListItems) or not exists(select id from #PriceListItems))
) rc

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#fh add retail', @rc, null)

print convert(varchar,getdate(),108) + '	Коробки/прайсы'

-------------------------------------------------------------------------------
-- собираем ЛПУ/ВП/прайслисты и вообще половину данных, описывающую куда посылать
-------------------------------------------------------------------------------
--select * from #fh
-- таблица №lpuc используется как ниже для проверок испарвленных ошибок, так и в процедуре prepareLPULetters_LPUContracts
if object_id('tempdb.dbo.#lpuc')!=0 
	drop table #lpuc

select ID, ID_SubjectLPU, ID_Branch, StartDate,case isnull(ProlongationType,0) when 0 then '21000101' else EndDate end EndDate, isnull(IsForLetters,0) IsForLetters
into #lpuc
from lpucontract where ID_Parent is null and IsDirectAccess=1 and Status in (40,50)
create clustered index lpuc_idx on #lpuc(ID_SubjectLPU, StartDate, EndDate, ID_Branch, IsForLetters)

set @rc=@@ROWCOUNT if @ID_Session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#lpuc', (select count(*) from #lpuc), null)


-- таблица #plishort - это договора с ЛПУ для прайслистов (изначально пустые), умноженные на ДМС (без полисов!) но с датами применения программ.

--declare @date datetime = '20230808', @id_session uniqueidentifier, @deletePrevLetters int =0, @checkexisting int=1, @rc int
if object_id('tempdb.dbo.#plishort')!=0 
	drop table #plishort

select isnull(id_lpu, ID_SubjectU) ID_LPU, pli.ID_LPUNet, f.ID_Contract, ID_PriceListItem, ksstart, ksend, 
	--case when ksstart>convert(date,@date) then ksStart when ksend<convert(date,@date) then ksend else convert(date,@date) end ksDate,	-- Это дата для выбора договора
	case when ksstart>convert(date,@date) then ksStart else convert(date,@date) end ksDate,	-- 20231201 Если начало обслуживания впереди, то будущий договор. Если позади, то текущий
	isnull(isnull(cp.IsCentralizedServiceNeeded, rp.IsCentralizedServiceNeeded),0) IsCentralizedServiceNeeded,
	convert(uniqueidentifier, null) ID_LPUContract, convert(varchar(200), null) LPUContractError, 
	convert(int, null) LPUContractCount, convert(varchar(1), null) LPUCType, convert(varchar(4000), null) WrongIDs, convert(tinyint,null) ErrorCode,
	convert(uniqueidentifier, null) ID_LPUErrCorr
into #plishort
from #fh f
left join ContractProgram cp on cp.id=f.ID_ContractProgram
left join RetailContractProgram rp on rp.id=f.ID_ContractProgram
join PriceListItems pli on pli.id=f.ID_PriceListItem
left join (select ID_SubjectU, ID_LPUNet from LPUNetDetail group by ID_SubjectU, ID_LPUNet) netd on netd.ID_LPUNet = pli.ID_LPUNet 
group by isnull(id_lpu, ID_SubjectU), pli.ID_LPUNet, f.ID_Contract, ID_PriceListItem, ksstart, ksend, 
	isnull(isnull(cp.IsCentralizedServiceNeeded, rp.IsCentralizedServiceNeeded),0)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#plishort', @rc, null)

create clustered index priceCIdx on #plishort (ID_LPU)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#plishort index', null, null)

-- процедура заполнит ID_LPUContract или оставить его пустым и запишет в таблицу причину - ErrorCode и ErrorText
exec prepareLPULetters_LPUContractsFind @date, @ID_Session

create index priceSetCIdx on #plishort (ID_Contract, ksstart, ksend, ID_PriceListItem) include (ID_LPUContract)

--select errorcode, * from #errors where ID_LPUNet='35988171-82A0-4117-99F2-1E781A9CFE20' 
--select errorcode, * from #plishort where errorcode is null and ID_LPUNet='35988171-82A0-4117-99F2-1E781A9CFE20'
--select errorcode, * from #plishort where ID_LPUNet='35988171-82A0-4117-99F2-1E781A9CFE20' and id_lpu='121F143D-58DC-49BD-BA8F-2231DC2E0F18'

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#plishort index 2', null, null)

--select errorcode,* from #plishort where id_lpunet = 'F463DE93-DC73-4BA2-95B9-B8C85254C9BD'

-- теперь попробуем для сетей (сети живут отдельно) подставить договора ЛПУ из обработанных ошибков
-- для несетевых ЛПУ договора подставляются ниже при формировании таблицы #pe
update p set ID_LPUContract = errCorr.ID_LPUContract, ID_LPUErrCorr = errCorr.ID, ErrorCode = null, LPUContractError = null 
--select errCorr.*, cpp.*, p.*
from #plishort p
join (select ID_PriceListItem, ksStart, ksEnd, ID_ContractPolicy, ID_Contract, ID_ContractProgram, ID_ContractProgramElement, ID_LPUAccessKind from #fh 
	group by ID_PriceListItem, ksStart, ksEnd, ID_ContractPolicy, ID_Contract, ID_ContractProgram, ID_ContractProgramElement, ID_LPUAccessKind) cpp 
		on p.ID_PriceListItem=cpp.ID_PriceListItem and p.ID_Contract=cpp.ID_Contract and p.ksStart=cpp.ksStart and p.ksEnd=cpp.ksEnd
cross apply (select top 1 c.ID, ID_LPUContract from LPULetterErrors c 
	where ID_LPUContract is not null and c.ErrorCode = 2 
		and ID_LPUContract in (select id from #lpuc) -- контракт корректен!
		and (c.ID_Contract=p.ID_Contract or c.ID_RetailContract = p.ID_Contract) 
		and (c.ID_ContractPolicy=cpp.ID_ContractPolicy or c.ID_ContractPolicy is null)
		and (c.ID_ContractProgram=cpp.ID_ContractProgram or c.ID_RetailContractProgram=cpp.ID_ContractProgram)
		and (c.ID_PriceListItem=p.ID_PriceListItem)
		and (c.ID_ContractProgramElement=cpp.ID_ContractProgramElement or c.ID_RetailProgramElement=cpp.ID_ContractProgramElement )
		and (c.ID_LPUAccessKind=cpp.ID_LPUAccessKind)
		and (c.ID_LPUNet=p.ID_LPUNet)
		and c.ID_LPU = p.ID_LPU
		and c.ChangeDate between p.ksstart and p.ksend 
		order by c.ChangeDate desc, c.OccuredLastTime desc) errCorr
where p.ID_LPUNet is not null and ErrorCode=2


print convert(varchar,getdate(),108) + '	Договора/ЛПУ/Сети'

--select * from #plishort
--declare @date datetime = '20230808',@TOLPURegion		tinyint = 0


if object_id('tempdb.dbo.#lpud')!=0 
	drop table #lpud

select ID, ID_SubjectLPU, Code, IsInactive, IsMain, IsMain2, indefiniteMain into #lpud from LPUDepartmetAtiveMain where  (@TOLPURegion is null or @TOLPURegion=IsNotRegion)
create clustered index lpudep_idx on #lpud (id)

-- Вкрацце про выбор ТО ЛПУ
-- 1. Если на ЛПУ GenerateLettersByDepartments=0, то всегда берём LPUDeartmant.IsMain=1 (IsMain2 для вьюшки LPUDepartmetAtiveMain)
-- 2. Если на ЛПУ GenerateLettersByDepartments=1 и указан PriceListItems.ID_LPUDepartment, то в него и шлём
-- 3. Если на ЛПУ GenerateLettersByDepartments=1 и не указан PriceListItems.ID_LPUDepartment и отсутствуют записи в PreAdvanceLPUDepartment/FactProgramLPUDepartment, то шлём во все LPUDepartments.IsInactive=0
-- 4. Если на ЛПУ GenerateLettersByDepartments=1 и не указан PriceListItems.ID_LPUDepartment и есть записи в PreAdvanceLPUDepartment/FactProgramLPUDepartment, то шлём во все LPUDepartments перечисленные там.
-- Если в рассылку попадёт неактивный LPUDepartment, то и хрен сним - сгенерит ошибку в конце.
-- Если IsMain2 не равно IsMain (два IsMain на одно ЛПУ или нет IsMain), то и хрен сним - сгенерит ошибку в конце.

-- сбор #pe делим на две части: сначала #deptPE, потом #pe
if object_id('tempdb.dbo.#deptPE')!=0 
	drop table #deptPE

select pli.id, IsPrepaid, pli.ID_LPU, pli.ID_LPUNet, lpud.id ID_LPUDepartment, isnull(PreAdvanceNumber,'') advNum, isnull(FactProgramCode,'') factCode, 
		PreAdvanceName advName,  FactProgramName factname, 
		indefiniteMain,	GenerateLettersByDepartments, slpu.code LPUCode, lpud.Code DeptCode
into #deptPE
from pricelistitems pli
join SubjectLPU slpu on slpu.id = pli.ID_LPU
outer apply(select pdp.ID_LPUDepartment from PreAdvanceLPUDepartment  pdp where pdp.ID_LPUContractPreAdvance =pli.ID_LPUContractPreAdvance  and slpu.GenerateLettersByDepartments=1
				union 
			select pdp.ID_LPUDepartment from FactProgramLPUDepartment pdp where pdp.ID_LPUContractFactProgram=pli.ID_LPUContractFactProgram and slpu.GenerateLettersByDepartments=1) afDep
join #lpud lpud on lpud.ID_SubjectLPU=pli.ID_LPU											-- всегда шлём в ЛПУ, указанного в прайсе 
	and ((pli.ID_LPUDepartment is not null and lpud.id=pli.ID_LPUDepartment 
					and slpu.GenerateLettersByDepartments!=0)								-- если надо слать по отдельным ТО и ТО указано в прайсе, то шлём в ТО
			or (pli.ID_LPUDepartment is null and slpu.GenerateLettersByDepartments!=0 
					and lpud.IsInactive=0 and afDep.ID_LPUDepartment is null)				-- если надо слать по отдельным ТО, но ТО в прайсе не указано и отсутствуют ТО для АФ ПЛ, то во все активные ТО шлём
			or (pli.ID_LPUDepartment is null and slpu.GenerateLettersByDepartments!=0 
					and afDep.ID_LPUDepartment = lpud.ID)									-- если надо слать по отдельным ТО, и ТО в прайсе не указано, но есть ТО для АФ ПЛ, то шлём в последние , не глядя на активность
			or (lpud.IsMain2!=0 and slpu.GenerateLettersByDepartments=0)					-- если надо только в головное ТО, то выбираем в качестве ТО ЛПУ IsMain ВСЕГДА
		)
left join LPUContractPreAdvance advC on advC.ID=pli.ID_LPUContractPreAdvance
left join LPUContractFactProgram factC on factC.id=pli.ID_LPUContractFactProgram
where pli.ID_LPUNet is null and  pli.id in (select distinct ID_PriceListItem from #fh)
union all 
select top 0 null,null,null,null,null,null,null,null,null,null,null,null,null

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#deptPE: LPU', @rc, null)

insert #deptPE
select pli.id, IsPrepaid, pli.ID_LPU, pli.ID_LPUNet, null ID_LPUDepartment, isnull(PreAdvanceNumber,'') advNum, isnull(FactProgramCode,'') factCode, 
		PreAdvanceName advName,  FactProgramName factname, 
		0 indefiniteMain,	GenerateLettersByDepartments, null LPUCode, substring(net.LetterName,1,10) DeptCode
from pricelistitems pli
join LPUNet net on net.id = pli.ID_LPUNet
left join LPUContractPreAdvance advC on advC.ID=pli.ID_LPUContractPreAdvance
left join LPUContractFactProgram factC on factC.id=pli.ID_LPUContractFactProgram
--	and (@TOLPURegion is null or @TOLPURegion=lpud.IsNotRegion)
where pli.id in (select distinct ID_PriceListItem from #fh)
--select code, IsNotRegion, name from dbo.LPUDepartmetAtiveMain where code like '757%'IsNotRegion=1

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#deptPE: LPUNet', @rc, null)

create clustered index detp1_idx on #deptPE (ID)

--declare @date datetime = '20230808',@TOLPURegion		tinyint 

if object_id('tempdb.dbo.#pe')!=0 
	drop table #pe
	
select LPUCode,DeptCode, 
	cpp.src,cpp.ID_ContractPolicy,cpp.ID_Contract,cpp.id_contractdetail,cpp.ID_ContractProgramElement,cpp.ID_ContractProgram,cpp.ID_ContractPolicyPrograms,cpp.ID_PriceListItem,
	cpp.ID_LPUAccessKind,cpp.ID_ContractProgramElementKS,cpp.FranchiseBlockLevel,cpp.progStart,cpp.progEnd,cpp.StartDate,cpp.enddate,cpp.ksStart,cpp.ksEnd,isnull(cpp.FranchiseInterest,0) FranchiseInterest,
	stisp.id ID_MedicineServiceType,
	isnull(case when cpp.startDate<fhp.StartDate then fhp.StartDate else cpp.startdate end,cpp.startDate) fhiStart, 
	isnull(case when cpp.EndDate>fhp.EndDate then fhp.EndDate else cpp.enddate end,cpp.EndDate) fhiEnd, 
	case when cpp.ksStart>cpp.ksend then 1 else isnull(fhp.FranchiseStatus, 1-isnull(sign(cpp.FranchiseInterest),0)) end fhpStatus, 
	stisp.Name AidName, advNum, factCode, advName, factname, 
	dbo.EmptyUID(case when p.ID_LPUNet is null then p.ID_LPU else null end) ID_LPU, dbo.EmptyUID(lpud.ID_LPUDepartment) ID_LPUDeptSend, dbo.EmptyUID(p.ID_LPUNet) ID_LPUNet, 
	dbo.EmptyUID(isnull(case when p.ID_LPUNet is null then case IsError when 0 then p.ID_LPUContract end end, errCorr.ID_LPUContract)) ID_LPUContract, 
	isPrepaid, case when cpp.src>9 then 1 else 0 end isretail, indefiniteMain, ID_LPUErrCorr,
	dbo.LPULetterKeyHash(cpp.ID_ContractPolicy,lpud.ID_LPUDepartment,cpp.ID_LPUAccessKind,p.ID_LPUNet,p.ID_LPU,isPrepaid) lpuHash
into #pe
from #fh cpp
join (select ID_Contract,case when ID_LPUNet is null then ID_LPU end ID_LPU,case when ID_LPUNet is null then ID_LPUContract end ID_LPUContract,ID_LPUNet, ID_PriceListItem, ksEnd, ksStart,
		case when ErrorCode is null then 0 else 1 end IsError, WrongIDs from #plishort p
		group by ID_Contract,case when ID_LPUNet is null then ID_LPU end,case when ID_LPUNet is null then ID_LPUContract end,ID_LPUNet, ID_PriceListItem, 
			ksEnd, ksStart, case when ErrorCode is null then 0 else 1 end, WrongIDs) p on p.ID_PriceListItem=cpp.ID_PriceListItem and p.ID_Contract=cpp.ID_Contract and p.ksStart=cpp.ksStart and p.ksEnd=cpp.ksEnd
join (select stisp.ID_Object, mst.Name, mst.id from ServiceTypeInStandardProgram stisp, MedicineServiceType mst where stisp.ID_ServiceType = mst.id) stisp on stisp.ID_Object = cpp.ID_PriceListItem
left join #deptPE lpud on lpud.ID=cpp.ID_PriceListItem
left join (select ID_ContractPolicy, FranchiseStatus, convert(datetime,convert(date,StartDate)) StartDate, convert(datetime,convert(date,EndDate-1)) EndDate 
			from ContractPolicyFranchiseStatusHistory where (StartDate<EndDate or EndDate is null ) 
			group by ID_ContractPolicy, FranchiseStatus, convert(datetime,convert(date,StartDate)), convert(datetime,convert(date,EndDate-1))) fhp on fhp.ID_ContractPolicy = cpp.ID_ContractPolicy 
							and fhp.StartDate <= cpp.EndDate and (fhp.enddate>=cpp.startdate or fhp.enddate is null)
-- Вариант точечного исправления ошибок через прямо в LetterErrors
-- Внимание!!! Тут можно исправить только ЛПУ, сети исправляются (проверяются) ниже после создания писем
outer apply (select top 1 c.ID ID_LPUErrCorr, ID_LPUContract from LPULetterErrors c 
	where p.IsError = 1 and ID_LPUContract is not null and c.ErrorCode = 2 
		and ID_LPUContract in (select id from #lpuc)	-- контракт корректен!
		and (c.ID_Contract=p.ID_Contract or c.ID_RetailContract = p.ID_Contract) 
		and (c.ID_ContractPolicy=cpp.ID_ContractPolicy or c.ID_ContractPolicy is null)
		and (c.ID_ContractProgram=cpp.ID_ContractProgram or c.ID_RetailContractProgram=cpp.ID_ContractProgram)
		and (c.ID_PriceListItem=p.ID_PriceListItem)
		and (c.ID_ContractProgramElement=cpp.ID_ContractProgramElement or c.ID_RetailProgramElement=cpp.ID_ContractProgramElement )
		and (c.ID_LPU=p.ID_LPU) -- or p.ID_LPU is null)
		and (c.ID_LPUDepartment=lpud.ID_LPUDepartment) -- or lpud.ID_LPUDepartment is null)
		and (c.ID_LPUAccessKind=cpp.ID_LPUAccessKind)
		--and (c.ID_LPUNet=p.ID_LPUNet or p.ID_LPUNet is null)
		and c.ChangeDate between p.ksstart and p.ksend 
		order by c.ChangeDate desc, c.OccuredLastTime desc ) errCorr

/* 
--Вариант массового исправления ошибок через ErrorCorrection
outer apply (select top 1 c.ID ID_Correction, ID_LPUContract from dbo.LPULetterErrorCorrections c 
	where p.IsError = 1 and p.WrongIDs=c.LPUContractSnapshot 
		and case when p.ksstart>convert(date,@date) then p.ksStart when p.ksend<convert(date,@date) then p.ksend else convert(date,@date) end between c.FromDate and c.ToDate
		and (c.ID_Contract=p.ID_Contract or c.ID_Contract is null) 
		and (c.ID_ContractPolicy=cpp.ID_ContractPolicy or c.ID_ContractPolicy is null)
		and (c.ID_ContractProgram=cpp.ID_ContractProgram or c.ID_ContractProgram is null)
		and (c.ID_PriceListItem=p.ID_PriceListItem or c.ID_PriceListItem is null)
		and (c.ID_ContractProgramElement=cpp.ID_ContractProgramElement or c.ID_ContractProgramElement is null)
		and (c.ID_LPU=p.ID_LPU or c.ID_LPU is null)
		and (c.ID_LPUAccessKind=cpp.ID_LPUAccessKind or c.ID_LPUAccessKind is null)
		and (c.ID_LPUNet=p.ID_LPUNet or c.ID_LPUNet is null)
		--and (c.ID_Responsible=@ID_Responsible or c.ID_Responsible is null)						
		order by c.ID_ContractPolicy desc, c.ID_PriceListItem desc, c.ID_ContractProgramElement desc, c.ID_ContractProgram desc, c.ID_LPU desc, 
				c.ID_LPUNet desc, c.ID_Contract desc, c.ID_LPUAccessKind desc, c.ID_Responsible desc) errCorr
*/
--where cpp.ID_PriceListItem='7F24AD56-EAAA-4FC4-9B85-392FF7CA8E2E'
--order by ID_ContractPolicy, ID_LPU,cpp.startdate
--select * from #pe where ID_ContractPolicy='11D0C014-86B1-4E34-8690-F9C5BE1CC427'

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#pe', @rc, null)

--select * from #plishort
--select * from #pe where ksEnd>ksStart
--select * from #fh
--declare @cnt int

select @rc = count(*) from #pe
print convert(varchar,getdate(),108) + '	Виды помощи/ТО ЛПУ/Активность франшыз: ' + convert(varchar,@rc)

create clustered index peProcIdx on #pe (ID_ContractPolicy, id_lpunet,id_lpu, ID_LPUDeptSend, id_lpucontract, isprepaid, id_lpuaccesskind, startdate, enddate)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#pe index', null, null)

-- для исправлениея (перепрогона) ошибок удаляем лишнее, т.е. те пары полисов-лпу, которых нет в исправленных ошибках
if @ErrCorrections is not null
	delete p from #pe p 
	where not exists(select 1 from #ErrCorrections e where e.ID_ContractPolicy=p.ID_ContractPolicy 
				and e.ID_LPU=p.ID_LPU and e.ID_LPUDepartment=p.ID_LPUDeptSend and e.ID_LPUNet=p.id_lpunet and e.IsAdvance=p.IsPrepaid)
				
set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#pe <- #eerCorrection', @rc, null)

-- контроль исправленнного - чистим исправление в #pe, если исправленный договор ЛПУ уже сдох
update pe set ID_LPUErrCorr = null, ID_LPUContract = dbo.EmptyUID(null) from #pe pe
where pe.ID_LPUErrCorr is not null and not exists(select 2 from #lpuc lc where lc.ID=pe.ID_LPUContract and pe.ID_LPU = lc.ID_SubjectLPU)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#pe <- corr control', @rc, null)
/*
-- Определим что нам надо обсчитать в цикле сравнения писем
-- Шаг 1: всё, что попало в предыдущий расчёт
if object_id('tempdb.dbo.#pcl')!=0 
	drop table #pcl

select ID_ContractPolicy, ID_LPU, ID_LPUNet 
into #pcl 
from #fh, pricelistitems pli --#pe 
where ID_PriceListItem=pli.id
group by ID_ContractPolicy, ID_LPU, ID_LPUNet


set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#pcl: calc',@rc, null)

create clustered index pclUIdx on #pcl (ID_ContractPolicy, ID_LPU, ID_LPUNet)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#pcl index',null, null)
*/


if object_id('tempdb.dbo.#fh')!=0 and @deletePrevLetters is null
	drop table #fh
if object_id('tempdb.dbo.#deptPE')!=0 and @deletePrevLetters is null
	drop table #deptPE


set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) 
		select @ID_Session, '#pe:', null, 'Contract: '+convert(varchar,count(distinct cp.id_contract))+
		'; CPolicy: '+convert(varchar,count(distinct cp.id))+
		'; RetailContract: '+convert(varchar,count(distinct rp.ID_RetailContract))+
		'; RPolicy: '+convert(varchar,count(distinct rp.id))+
		'; LPU: '+convert(varchar,count(distinct dbo.nullUID(ID_LPU)))+
		'; Dept: '+convert(varchar,count(distinct dbo.nullUID(ID_LPUDeptSend)))+
		'; Net: '+convert(varchar,count(distinct dbo.nullUID(ID_LPUNet)))
		from #pe
		left join contractpolicy cp on cp.id=#pe.id_contractpolicy
		left join retailcontractpolicy rp on rp.id=#pe.id_contractpolicy



------------------------------------------------------------------------------------------------------------
-- Хитровычурный код для получения цепочки состояний - таблички типа Дата-Дата-Сервисы_в_периоде
------------------------------------------------------------------------------------------------------------
--declare @date datetime = getdate()

if object_id('tempdb.dbo.#TRpea')!=0 
	drop table #TRpea

SELECT deptcode, b eDate,-- (cppAttach),(cppDetach),(ksAttach),(ksDetach),(progEnd),(progStart),(fhpStart),(fhpEnd),(fhiStart),(fhiEnd),
		p1.ID_ContractPolicy, p1.id_lpu, p1.ID_LPUDeptSend, p1.id_lpunet, p1.isPrepaid, 
		-- По некоторому размышлению, если нам не надо делать открепы-прикрепы при смене договора ЛПУ, то вообще можно выкинуть его из рассмотрения
		-- при сборке цепочки состояний. Позже, при формировании письма, вытащим необходимый договор из #pe. Там же обнаружим ошибку, если договоров 
		-- окажется несколько
		id_lpucontract, 
		p1.ID_LPUAccessKind, isretail, min(progStart) progstart, max(progend) progend,
		ROW_NUMBER() OVER (PARTITION BY ID_ContractPolicy, id_lpu, ID_LPUDeptSend, id_lpunet, isprepaid, 
		id_lpucontract, ID_LPUAccessKind, isretail ORDER BY b) AS rn
into #TRpea
	FROM #pe p1
	join (select min(progstart) mprog, ID_ContractPolicy pol, id_lpu lpu , ID_LPUDeptSend dept, id_lpunet net, isPrepaid prep, id_lpucontract lpuc, ID_LPUAccessKind ak
			from #pe p2 group by ID_ContractPolicy, id_lpu, ID_LPUDeptSend, id_lpunet, isPrepaid, id_lpucontract, ID_LPUAccessKind) mp
		on ID_ContractPolicy=pol and id_lpu=lpu  and ID_LPUDeptSend=dept and id_lpunet=net and isPrepaid=prep and id_lpucontract=lpuc and ID_LPUAccessKind=ak
	cross apply (select b b from (values (ksStart),(startdate),(startDate-case when startDate>mprog then 1 else 0 end),
				(fhiStart-case when fhiStart>mprog then 1 else 0 end),(ksEnd),(endDate),(fhiStart),(fhiEnd),(progstart),(progEnd)) as d(b) group by b) s
	where ksStart<=ksEnd
	group by deptcode, b, ID_ContractPolicy, id_lpu, ID_LPUDeptSend, id_lpunet, isPrepaid, id_lpucontract, ID_LPUAccessKind, isretail--, progStart, progend --,b
--select * from #pe where isPrepaid=0 and DeptCode='676-0' order by ID_ContractPolicy, startDate	
print convert(varchar,getdate(),108) + '			#TRpea: ' + convert(varchar,@@rowcount)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#TRpea', @rc, null)

create clustered index trpea_Idx on #TRpea(ID_ContractPolicy, id_lpu, ID_LPUDeptSend, id_lpunet, isPrepaid, id_lpucontract, ID_LPUAccessKind, edate, rn)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#TRpea index', null, null)


--declare @date datetime = '20230808', @id_session uniqueidentifier, @deletePrevLetters int =0, @checkexisting int=1, @rc int
if object_id('tempdb.dbo.#pea')!=0 
	drop table #pea
	
select p1.deptcode, p1.StartDate, p1.Enddate, p1.ID_ContractPolicy, p1.id_lpu, p1.ID_LPUDeptSend, p1.id_lpunet, p1.isPrepaid, p1.id_lpucontract, p1.ID_LPUAccessKind, p1.isretail, p1.progstart, p1.progEnd, 
		isnull(stuff((select distinct '; '+ ltrim(rtrim(aidname)) s from #pe pp 
			where aidname!=''
				and p1.Enddate between pp.ksStart and pp.ksEnd --and p1.StartDate between pp.ksStart and pp.ksEnd
				and not (p1.Enddate between pp.startDate and pp.endDate and FranchiseInterest!=0 and not (p1.Enddate between pp.fhiStart and pp.fhiEnd and fhpStatus=1)) 
				and not (p1.Enddate between pp.fhiStart and pp.fhiEnd and fhpStatus != 1 and FranchiseInterest!=0) 
				and ID_ContractPolicy = p1.ID_ContractPolicy and id_lpu = p1.id_lpu and ID_LPUDeptSend=p1.ID_LPUDeptSend 
				and id_lpunet = p1.id_lpunet and isprepaid = p1.isPrepaid and id_lpucontract = p1.id_lpucontract  and ID_LPUAccessKind = p1.ID_LPUAccessKind
			order by '; '+ltrim(rtrim(aidname)) for xml path(''),type).value('.', 'nvarchar(4000)'),1,2,''),'') aid,
		isnull(stuff((select distinct '; '+ ltrim(rtrim(advNum)) s from #pe pp 
			where advNum!=''
				and p1.Enddate between pp.ksStart and pp.ksEnd --and p1.StartDate between pp.ksStart and pp.ksEnd
				and not (p1.Enddate between pp.startDate and pp.endDate and FranchiseInterest!=0 and not (p1.Enddate between pp.fhiStart and pp.fhiEnd and fhpStatus=1)) 
				and not (p1.Enddate between pp.fhiStart and pp.fhiEnd and fhpStatus != 1 and FranchiseInterest!=0) 
				and ID_ContractPolicy = p1.ID_ContractPolicy and id_lpu = p1.id_lpu and ID_LPUDeptSend=p1.ID_LPUDeptSend 
				and id_lpunet = p1.id_lpunet and isprepaid = p1.isPrepaid and id_lpucontract = p1.id_lpucontract  and ID_LPUAccessKind = p1.ID_LPUAccessKind
			order by '; '+ltrim(rtrim(advNum)) for xml path(''),type).value('.', 'nvarchar(4000)'),1,2,''),'') adv,
		isnull(stuff((select distinct '; '+ ltrim(rtrim(factCode)) s from #pe pp 
			where factCode!=''
				and p1.Enddate between pp.ksStart and pp.ksEnd --and p1.StartDate between pp.ksStart and pp.ksEnd
				and not (p1.Enddate between pp.startDate and pp.endDate and FranchiseInterest!=0 and not (p1.Enddate between pp.fhiStart and pp.fhiEnd and fhpStatus=1)) 
				and not (p1.Enddate between pp.fhiStart and pp.fhiEnd and fhpStatus != 1 and FranchiseInterest!=0) 
				and ID_ContractPolicy = p1.ID_ContractPolicy and id_lpu = p1.id_lpu and ID_LPUDeptSend=p1.ID_LPUDeptSend 
				and id_lpunet = p1.id_lpunet and isprepaid = p1.isPrepaid and id_lpucontract = p1.id_lpucontract  and ID_LPUAccessKind = p1.ID_LPUAccessKind
			order by '; '+ ltrim(rtrim(factCode)) for xml path(''),type).value('.', 'nvarchar(4000)'),1,2,''),'') fact,
		convert(varchar(10),'') pEnd, 
		case when enddate<convert(date,@date) then -1 else 0 end rn--ROW_NUMBER() OVER (PARTITION BY p1.ID_ContractPolicy, p1.id_lpu, p1.ID_LPUDeptSend, p1.id_lpunet, p1.isprepaid, p1.id_lpucontract, p1.ID_LPUAccessKind, p1.isretail ORDER BY p1.startdate) AS rn, 
		,identity(int,1,1) ID_PEA,
		dbo.LPULetterKeyHash(p1.ID_ContractPolicy,p1.ID_LPUDeptsend,p1.ID_LPUAccessKind,p1.ID_LPUNet,p1.ID_LPU,p1.isPrepaid) lpuHash
into #pea 
from (select p1.deptcode, case p1.rn when 1 then p1.edate else case when p1.eDate<p1.progend then p1.eDate+1 else p1.edate end end StartDate, p2.edate Enddate, 
		p1.ID_ContractPolicy, p1.id_lpu, p1.ID_LPUDeptSend, p1.id_lpunet, p1.isPrepaid, p1.id_lpucontract, p1.ID_LPUAccessKind, p1.isretail, max(p1.progstart) progstart, max(p1.progEnd) progEnd 
	from #TRpea p1
	join #TRpea p2 on p2.ID_ContractPolicy=p1.ID_ContractPolicy and p2.id_lpu=p1.id_lpu and p2.ID_LPUDeptSend=p1.ID_LPUDeptSend and p2.id_lpunet=p1.id_lpunet and p2.isprepaid = p1.isPrepaid 
		and p2.id_lpucontract=p1.id_lpucontract and p2.ID_LPUAccessKind = p1.ID_LPUAccessKind and (p2.rn = p1.rn+1 /*or p2.rn = p1.rn*/)-- and p2.progEnd=p1.progEnd and p1.isretail=p2.isretail
	--where p1.deptcode='009-0'
	group by p1.deptcode, case p1.rn when 1 then p1.edate else case when /*p1.edate > p1.progStart and*/ p1.eDate<p1.progend then p1.eDate+1 else p1.edate end end , p2.edate, 
		p1.ID_ContractPolicy, p1.id_lpu, p1.ID_LPUDeptSend, p1.id_lpunet, p1.isPrepaid, p1.id_lpucontract, p1.ID_LPUAccessKind, p1.isretail--, p1.progstart, p1.progEnd
	) p1

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#pea', @rc, null)

/*
Собственно тут собрали таблицу #pea: период, ВП, ключи полиса/лпу
Дальше начинаем её ужимать, сливая периоды с одинаковыми ВП и ключом полиса в один период
*/

print convert(varchar,getdate(),108) + '			pea: ' + convert(varchar,@@rowcount)
--select * from #pea

-- 20231208 Странное: выгребаем однодневную запись в начале изменённой программы -->
update p2 set startdate=p1.startdate -- select * 
from #pea p1, #pea p2 where p1.startdate=p1.enddate and p1.Enddate+1=p2.StartDate
	and p2.ID_ContractPolicy=p1.ID_ContractPolicy and p2.id_lpu=p1.id_lpu and p2.ID_LPUDeptSend=p1.ID_LPUDeptSend and p2.id_lpunet=p1.id_lpunet 
	and p2.isprepaid = p1.isPrepaid and p2.id_lpucontract=p1.id_lpucontract and p2.ID_LPUAccessKind = p1.ID_LPUAccessKind
	and p1.aid=p2.aid and p1.adv=p2.adv and p1.fact=p2.fact


delete p1 --select * 
from #pea p1, #pea p2 where p1.startdate=p1.enddate and p1.Enddate=p2.StartDate and p2.StartDate!=p2.Enddate
	and p2.ID_ContractPolicy=p1.ID_ContractPolicy and p2.id_lpu=p1.id_lpu and p2.ID_LPUDeptSend=p1.ID_LPUDeptSend and p2.id_lpunet=p1.id_lpunet 
	and p2.isprepaid = p1.isPrepaid and p2.id_lpucontract=p1.id_lpucontract and p2.ID_LPUAccessKind = p1.ID_LPUAccessKind
	and p1.aid=p2.aid and p1.adv=p2.adv and p1.fact=p2.fact
-- 20231208 Странное: выгребаем однодневную запись в начале изменённой программы <--


if object_id('tempdb.dbo.#TRpea')!=0 and @deletePrevLetters is null
	drop table #TRpea
	
create clustered index pea_Idx on #pea(ID_ContractPolicy, id_lpu, ID_LPUDeptSend, id_lpunet, id_lpucontract, ID_LPUAccessKind, isPrepaid, progend)
create index pea2_Idx on #pea(id_lpu, ID_LPUDeptSend, id_lpunet) include(ID_ContractPolicy)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#pea index', null, null)

--select * from #TRpea where isPrepaid=0 and DeptCode='676-0' order by ID_ContractPolicy, eDate
--select * from #pea where isPrepaid=0 and DeptCode='676-0' order by ID_ContractPolicy, StartDate
--select * from #pe where isPrepaid=0 and DeptCode='676-0' order by ID_ContractPolicy, StartDate
--declare @date datetime = getdate(), @rc int, @id_session uniqueidentifier, @deletePrevLetters int=0
declare @peaStep int = 0, @peaRC int 

while 1=1
begin 
	set @peaStep = @peaStep + 1

	delete p1 from #pea p1,(select p1.ID_ContractPolicy, p1.id_lpu, p1.ID_LPUDeptSend, p1.id_lpunet, p1.isPrepaid, p1.id_lpucontract, p1.ID_LPUAccessKind, p1.aid, p1.adv, p1.fact, --p1.progEnd, 
					p1.StartDate s, p1.EndDate e, max(id_pea) i
				from #pea p1
				group by p1.ID_ContractPolicy, p1.id_lpu, p1.ID_LPUDeptSend, p1.id_lpunet, p1.isPrepaid, p1.id_lpucontract, p1.ID_LPUAccessKind, p1.aid, p1.adv, p1.fact/*, p1.progEnd*/, p1.StartDate, p1.EndDate) p2 
	where p2.ID_ContractPolicy=p1.ID_ContractPolicy and p2.id_lpu=p1.id_lpu and p2.ID_LPUDeptSend=p1.ID_LPUDeptSend and p2.id_lpunet=p1.id_lpunet 
				and p2.isprepaid = p1.isPrepaid and p2.id_lpucontract=p1.id_lpucontract and p2.ID_LPUAccessKind = p1.ID_LPUAccessKind
				and p1.aid=p2.aid and p1.adv=p2.adv and p1.fact=p2.fact-- and p1.progEnd=p2.progEnd 	
				and startdate=s and enddate=e and id_pea!=i
	--declare @date datetime = '20230808'
	update p1 set StartDate=s, EndDate=e, rn = case when e<convert(date,@date) then -1 else 0 end, progEnd = prE
	--select p1.id, p1.ID_ContractPolicy, p1.deptcode, p1.StartDate, p1.Enddate, p1.aid, s, e, p2.aid, p2.id
	from #pea p1,(select p1.ID_ContractPolicy,  p1.id_lpu, p1.ID_LPUDeptSend, p1.id_lpunet, p1.isPrepaid, p1.id_lpucontract, p1.ID_LPUAccessKind, p1.aid, p1.adv, p1.fact, 
					case when max(p2.progEnd)>max(p1.progEnd) then max(p2.progEnd) else max(p1.progEnd) end prE, --max(p1.progEnd) prE, 
					max(case when p1.StartDate>p2.StartDate then p2.StartDate else p1.StartDate end) s, 
					max(case when p1.endDate>p2.endDate then p1.endDate else p2.endDate end) e
				from #pea p1, #pea p2 where p2.ID_ContractPolicy=p1.ID_ContractPolicy and p2.id_lpu=p1.id_lpu and p2.ID_LPUDeptSend=p1.ID_LPUDeptSend and p2.id_lpunet=p1.id_lpunet 
							and p2.isprepaid = p1.isPrepaid and p2.id_lpucontract=p1.id_lpucontract and p2.ID_LPUAccessKind = p1.ID_LPUAccessKind
							and p1.aid=p2.aid and p1.adv=p2.adv and p1.fact=p2.fact /* and p1.progEnd=p2.progEnd*/ and p1.ID_PEA!=p2.ID_PEA
							and p1.enddate >= p2.StartDate-1 and p1.StartDate-1<p2.Enddate
							-- 20231208 Странное: периоды с пустыми договорами не будем сливать. Пусть остаются для контроля -->
							and not (p1.ID_LPUContract=dbo.EmptyUID(null) and p1.ID_LPU!=dbo.EmptyUID(null))
							-- 20231208 Странное: периоды с пустыми договорами не будем сливать. Пусть остаются для контроля <--
				group by p1.deptcode,p1.ID_ContractPolicy, p1.id_lpu, p1.ID_LPUDeptSend, p1.id_lpunet, p1.isPrepaid, p1.id_lpucontract, p1.ID_LPUAccessKind, p1.aid, p1.adv, p1.fact--, p1.progEnd
				) p2
	where p2.ID_ContractPolicy=p1.ID_ContractPolicy and p2.id_lpu=p1.id_lpu and p2.ID_LPUDeptSend=p1.ID_LPUDeptSend and p2.id_lpunet=p1.id_lpunet 
							and p2.isprepaid = p1.isPrepaid and p2.id_lpucontract=p1.id_lpucontract and p2.ID_LPUAccessKind = p1.ID_LPUAccessKind 
							and p1.aid=p2.aid and p1.adv=p2.adv and p1.fact=p2.fact /* and p1.progEnd=p2.progEnd*/ and (p1.StartDate!=s or EndDate!=e)
							and p1.StartDate between s and e and p1.EndDate between s and e

	set @peaRC = @@ROWCOUNT

	if @peaRC = 0 break

	set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#pea step '+convert(varchar,@peaStep),@peaRC, null)

end
-- Флажок отсутсвия сервисов для упрощения выбора типа письма
update #pea set pEnd = 'Emp' where aid='' and fact='' and adv=''

-- добавляем фейковую "запоследнюю" строку для полисов, открепленных раньше времени, чтобы сформированть единым запросом письмо на финальное неожиданное открепление
-- это для досрочно умерших полисов, чтобы был период на планировавшееся время действия но с пустыии уже ВП
-- такая запись позволит ниже легко и без допусловий сделать откреп
insert #pea (ID_ContractPolicy,id_lpu,ID_LPUDeptSend,id_lpunet,isPrepaid,id_lpucontract,ID_LPUAccessKind,DeptCode,startDate,EndDate,aid,adv,fact,pEnd,progEnd, isretail,rn, 
	lpuHash)
select ID_ContractPolicy,id_lpu,ID_LPUDeptSend,id_lpunet,isPrepaid,id_lpucontract,ID_LPUAccessKind,DeptCode,EndDate+1,progEnd,''aid,''adv,''fact, 'Emp'pEnd, progEnd, isretail,0, 
	dbo.LPULetterKeyHash(p1.ID_ContractPolicy,p1.ID_LPUDeptSend,p1.ID_LPUAccessKind,p1.ID_LPUNet,p1.ID_LPU,p1.isPrepaid) lpuHash
from #pea p1 where pEnd!='Emp' and progEnd>Enddate and not exists(select 1 from #pea p2 
						where p2.ID_ContractPolicy=p1.ID_ContractPolicy and p2.id_lpu=p1.id_lpu and p2.ID_LPUDeptSend=p1.ID_LPUDeptSend and p2.id_lpunet=p1.id_lpunet 
							and p2.isprepaid = p1.isPrepaid and p2.id_lpucontract=p1.id_lpucontract and p2.ID_LPUAccessKind = p1.ID_LPUAccessKind and p1.Enddate<p2.Startdate)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#pea add empties',@rc, null)

--select * from #pea where ID_ContractPolicy='10EED72E-4F4C-43E5-A1D8-A4ABF3BE16CA' and ID_LPUDeptSend='5CD42654-066F-4AE2-9C94-B83094A0D206' order by IsPrepaid,StartDate
--declare @cnt int

print convert(varchar,getdate(),108) + '	Собрали главную расчётную табличку с событиями (цепочку состояний) '
--select * from #pea where ID_ContractPolicy='10EED72E-4F4C-43E5-A1D8-A4ABF3BE16CA' and ID_LPUDeptSend='5DC53D94-538C-4440-AAC2-32102EF833A6' order by IsPrepaid,StartDate
--select rn,* from #pea order by ID_ContractPolicy, deptcode, StartDate

------------------------------------------------------------------------------------------------------------
-- Собираем существующие письма
------------------------------------------------------------------------------------------------------------

-- TODO: Наверное, при неуказанных в параметрах вызова процедуры полисах, следует взять все письма по договору страхования (или ЛПУ - смотря что указали)
-- TODO: и собрать по договоу/ЛПУ всё ранее посланное, чтобы открепить исчезнувшие полисы. Подумаю 

-- Определим что нам надо обсчитать в цикле сравнения писем
-- Шаг 1: всё, что попало в предыдущий расчёт
if object_id('tempdb.dbo.#pcl')!=0 
	drop table #pcl

select ID_ContractPolicy, ID_LPU, ID_LPUNet 
into #pcl 
from #pe 
group by ID_ContractPolicy, ID_LPU, ID_LPUNet

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#pcl: calc',@rc, null)

create clustered index pclUIdx on #pcl (ID_ContractPolicy, ID_LPU, ID_LPUNet)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#pcl index',null, null)

if @ErrCorrections is not null
begin 
	delete #pcl
	insert #pcl
	select ID_ContractPolicy, ID_LPU, ID_LPUNet from (select ID_ContractPolicy, dbo.EmptyUID(case when ID_LPUNet = dbo.EmptyUID(null) then ID_LPU end) ID_LPU, ID_LPUNet from #ErrCorrections 
									group by ID_ContractPolicy, dbo.EmptyUID(case when ID_LPUNet = dbo.EmptyUID(null) then ID_LPU end), ID_LPUNet) lf
	where not exists(select 1 from #pcl p where (p.ID_LPU=lf.ID_LPUNet or p.ID_LPU=lf.ID_LPU) and p.ID_ContractPolicy = lf.ID_ContractPolicy)
end
--select * from #pcl
--select * from #pea where DeptCode='676-0'
/*
insert #pcl
select lf.ID_ContractPolicy, ID_SubjectLPU, lf.ID_LPUNet 
from LPULetterFlow lf, ContractPolicy cp, PriceListitems pl, #PriceListItems p 
where ImportType in (0,1,2) and pl.id=p.id and (lf.ID_ContractPolicy in (select id from #PriceListItems) or not exists(select id from #PriceListItems))
	and (lf.ID_SubjectLPU=pl.ID_LPU or lf.ID_LPUNet=pl.ID_LPUNet) 
	and lf.ID_ContractPolicy = cp.ID
	and (lf.ID_ContractPolicy in (select id from #Policies) or not exists(select id from #Policies))
	and (cp.ID_Contract in (select id from #Contract) or not exists(select id from #Contract))
	and	not exists(select 1 from #pcl where ID_ContractPolicy=lf.ID_ContractPolicy and lf.ID_SubjectLPU=ID_SubjectLPU and lf.ID_LPUNet = ID_LPUNet)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#pcl-2',@rc, null)
*/

--TODO: Отладочное! Надо как-то будет подумать над сохранением этого добра 

/*declare  @date datetime = getdate(),  @id_session uniqueidentifier, @deletePrevLetters int =0, @rc int, 
	@GenCurrentState tinyint, @IsNotDuplicate tinyint,@ExpirationPeriod tinyint, @SPType tinyint, @letterDaysForward int = 30, @LetterDayLimit int = 3, @LetterCheckExisting tinyint=1,
	@ID_Signing uniqueidentifier ='5B61FCBD-2097-4DC9-BC32-4F471C9C885C',@ID_Responsible uniqueidentifier = 'BF6C4485-174B-4E9C-9F14-32B7DF8F26DD'		--*/
	
declare @shift int = 1;-- if (select count(distinct id_contractpolicy) from #pea p)<5 set @shift = 2000

if object_id('tempdb.dbo.#Letters')!=0 
	drop table #Letters

select convert(varchar(2),'') Tp, convert(uniqueidentifier,null) ID_Letter, 
	isnull((select top 1 code from #lpud ld where ld.id=lf.ID_LPUDepartment), 
		(select fullname from LPUNet nd where nd.ID=lf.ID_LPUNet)) ldCode,
		CD, case when DetachDate<convert(date,@date) then -1 else 0 end future, --datediff(day, @date, case ImportType when 1 then DetachDate+1 else case when AttachDate<Date then date else attachdate end end) Future,
		ID, dbo.EmptyUID(ID_SubjectLPU) ID_SubjectLPU, dbo.EmptyUID(ID_LPUNet) ID_LPUNet,dbo.EmptyUID(ID_LPUDepartment) ID_LPUDepartment,
		Date,ImportType, 
		dbo.EmptyUID(ID_LPUContract) ID_LPUContract,
		ID_LPUAccessKind,IsAdvance,ID_ContractPolicy,AttachDate,DetachDate,LetterType,IsRetail,
		isnull(BaseService,'') newAid, isnull(AdvService,'') newAdv, isnull(FactService,'') newFact,
		convert(varchar(1000), null) oldAid, convert(varchar(1000), null) OldAdv, convert(varchar(1000), null) oldFact, 
		0 isKS, @ID_Responsible ID_Responsible, @ID_Signing ID_Signing,
		dbo.LPULetterKeyHash(ID_ContractPolicy,ID_LPUDepartment,ID_LPUAccessKind,ID_LPUNet,ID_SubjectLPU,isAdvance) lpuHash
into #Letters 
from (--declare @date datetime = '20230808', @Shift int =0
	select lf.*, case lf.ImportType when 1 then lf.DetachDate+1 else lf.AttachDate end CD from LPULetterFlow lf, #pcl pli 
	where ImportType in (0,1,2)  and (lf.ID_LPUDepartment in (select id from #lpud) or lf.ID_LPUNet is not null)
		and (lf.IsAdvance = @AdvanceType or @AdvanceType is null)
		and lf.ID_ContractPolicy = pli.ID_ContractPolicy and (lf.ID_SubjectLPU=pli.ID_LPU or lf.ID_LPUNet=pli.ID_LPUNet)
		and convert(date,Date)<=convert(date,@date)				-- скорее отладочное, т.к. в бою вряд ли мы будем посылать письма задним числом, не рассматривая посланное после него. Хотя...
		--and ((ID_SubjectLPU in (select id_lpu from Pricelistitems where id_lpu is not null and id in (select id from #PriceListItems)) or not exists(select id from #PriceListItems)) 
			--or (ID_LPUNet in (select id_lpunet from Pricelistitems where id_lpunet is not null and id in (select id from #PriceListItems)) or not exists(select id from #PriceListItems)))
		--and (DetachDate >= convert(date,@date)-@shift) -- TODO: раскомментировать в боевой версии
) lf
where isnull(@GenCurrentState,0)=0	-- смешной ход: если занимаемся перегенирацией писем под сверку, то LEtters нам не нужен
	and (@ErrCorrections is null or exists(select 1 from #ErrCorrections ec where ec.ID_ContractPolicy=lf.ID_ContractPolicy
		and ec.ID_LPU=dbo.EmptyUID(lf.ID_SubjectLPU) and ec.ID_LPUNet=dbo.EmptyUID(lf.ID_LPUNet) and ec.ID_LPUDepartment=dbo.EmptyUID(lf.ID_LPUDepartment) and ec.IsAdvance=lf.IsAdvance))
--select * from #Letters order by ldCode, date
set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#Letters old',@rc, null)

print convert(varchar,getdate(),108) + '	letters-old: ' + convert(varchar,@@rowcount)

create clustered index letters_idx on #letters(ID_ContractPolicy,ID_LPUDepartment,ID_LPUNet,ID_LPUContract,ID_LPUAccessKind,IsAdvance,Date,cd)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#Letters index',null, null)

/*declare  @date datetime = getdate(),  @id_session uniqueidentifier, @deletePrevLetters int =0, @rc int, 
	@GenCurrentState tinyint, @IsNotDuplicate tinyint,@ExpirationPeriod tinyint, @SPType tinyint, @letterDaysForward int = 30, @LetterDayLimit int = 3, @LetterCheckExisting tinyint=1,
	@ID_Signing uniqueidentifier ='5B61FCBD-2097-4DC9-BC32-4F471C9C885C',@ID_Responsible uniqueidentifier = 'BF6C4485-174B-4E9C-9F14-32B7DF8F26DD'		--*/

-- Повторять генрацию последних писем полисам (=1), если генерировать более нечего,
-- то убираем последнее сгенрированное, чтобы начать от состояния "как тогда"


if @IsNotDuplicate = 1
begin
	declare @lastGen datetime = '19701224 00:15'
	
	--select @lastGen = max(date)-0.001 from #Letters lp where lp.letterType & 16 = 0

	if @ExpirationPeriod is not null
		set @lastGen = @date - @ExpirationPeriod 

	delete ld--	select * 
	from #Letters ld 
	join (select lp.ID_ContractPolicy,lp.ID_LPUDepartment,lp.ID_LPUNet,lp.IsAdvance,lp.ID_LPUContract,lp.ID_LPUAccessKind, 
			isnull(max(case lp.letterType & 16 when 0 then date end), min(case lp.letterType & 16 when 16 then date end)) Date
		from #Letters lp 
		group by lp.ID_ContractPolicy,lp.ID_LPUDepartment,lp.ID_LPUNet,lp.IsAdvance,lp.ID_LPUContract,lp.ID_LPUAccessKind
		) lp on (ld.date>=lp.date)
			and ld.ID_ContractPolicy=lp.ID_ContractPolicy and ld.ID_LPUDepartment=lp.ID_LPUDepartment and ld.ID_LPUNet=lp.ID_LPUNet 
			and ld.IsAdvance=lp.IsAdvance and ld.ID_LPUContract=lp.ID_LPUContract and ld.ID_LPUAccessKind=lp.ID_LPUAccessKind
	where ld.date >= @lastGen and ld.ImportType=isnull(@SPType,ld.ImportType)

end	


-- Напомню самому себе про значения младших битов @GenCurrentState
-- 1 - включает режим и посылает текущие активные полисы как прикрепы
-- 2 - посылает прикрепы и открепы также на полисы, которые активируются (умрут) в будущем
-- 4 - включает формироание открепов по умершим полисам, которые были активны ранее (при этом проверяется второй бит на предмет отсылки будущего открепа)

if @GenCurrentState&5=5		-- здесь готовим почву для открепов по умершим полисам
							-- по сути надо просто загнать в #Letters последний прикреп/замену c detachDate >= текущей у которой отсутствует 
							-- живое #pea на дату запуска
begin
	insert #Letters 
	/*declare  @date datetime = '20230808',  @id_session uniqueidentifier, @deletePrevLetters int =0, @rc int, 
		@GenCurrentState tinyint=7, @IsNotDuplicate tinyint=1,@ExpirationPeriod int, @SPType tinyint, @letterDaysForward int = 30, @LetterDayLimit int = 3, @LetterCheckExisting tinyint=1,
		@ID_Signing uniqueidentifier ='5B61FCBD-2097-4DC9-BC32-4F471C9C885C',@ID_Responsible uniqueidentifier = 'BF6C4485-174B-4E9C-9F14-32B7DF8F26DD'		--*/
	select convert(varchar(2),'') Tp, convert(uniqueidentifier,null) ID_Letter, 
	isnull((select top 1 code from LPUDepartment ld where ld.id=lf.ID_LPUDepartment), 
		(select fullname from LPUNet nd where nd.ID=lf.ID_LPUNet)) ldCode,
		CD, case when DetachDate<convert(date,@date) then -1 else 0 end future, --datediff(day, @date, case ImportType when 1 then DetachDate+1 else case when AttachDate<Date then date else attachdate end end) Future,
		ID, dbo.EmptyUID(ID_SubjectLPU) ID_SubjectLPU, dbo.EmptyUID(ID_LPUNet) ID_LPUNet,dbo.EmptyUID(ID_LPUDepartment) ID_LPUDepartment,
		Date,ImportType, 
		dbo.EmptyUID(ID_LPUContract) ID_LPUContract,
		ID_LPUAccessKind,IsAdvance,ID_ContractPolicy,AttachDate,DetachDate,LetterType,IsRetail,
		isnull(BaseService,'') newAid, isnull(AdvService,'') newAdv, isnull(FactService,'') newFact,
		convert(varchar(1000), null) oldAid, convert(varchar(1000), null) OldAdv, convert(varchar(1000), null) oldFact, 
		0, @ID_Responsible, @ID_Signing, 
		dbo.LPULetterKeyHash(ID_ContractPolicy,ID_LPUDepartment,ID_LPUAccessKind,ID_LPUNet,ID_SubjectLPU,isAdvance) lpuHash
	from (--declare @date datetime = '20230808', @Shift int =0
		select lf.*, case lf.ImportType when 1 then lf.DetachDate+1 else lf.AttachDate end CD from LPULetterFlow lf, #pcl pli
		where lf.ID_ContractPolicy = pli.ID_ContractPolicy and (lf.ID_SubjectLPU=pli.ID_LPU or lf.ID_LPUNet=pli.ID_LPUNet)
			and ((convert(date,date)<convert(date,@date) and ImportType in (0,2)))
			-- для открепов отживших полисов ищем посланные прикрепы старого у которых сегодня отсутствуют ВП
			and lf.DetachDate>=convert(date,@date)
			and not exists(select 1 from #pea p where lf.ID_ContractPolicy=p.ID_ContractPolicy and p.ID_LPUDeptSend=lf.ID_LPUDepartment 
						and p.ID_LPUNet=dbo.EmptyUID(lf.ID_LPUNet)
						and p.IsPrepaid=lf.IsAdvance and p.ID_LPUContract=lf.ID_LPUContract and p.ID_LPUAccessKind=lf.ID_LPUAccessKind
						and p.pEnd!='Emp' and convert(date,@date) between p.StartDate and p.Enddate)
	) lf
end

--/* 
-- ВНИМАНИЕ!!! Этот if отладочный! Он предназначен для хранения в #Letters всех прошлых писем и их красивиого отображения в диаграмме Excel
-- В реальном бою его можно заккоментировать
if 1=1--(select count(distinct id_contractpolicy) from #pea p)<5 and isnull(@deletePrevLetters,2)<2 --and 1=2
begin

	-- удаляем ставшие неактуальными старые письма, т.е. такие, которые переопределили изменение ранее определённого состояния (l2.Date>l1.date and l2.cd<=l1.cd)
	update l1 set future=-2 --delete l1 --select *
	from #letters l1 where exists(select 1 from #letters l2 where l1.ID_ContractPolicy=l2.ID_ContractPolicy and l2.ID_LPUDepartment=l1.ID_LPUDepartment and l2.ID_LPUNet=l1.ID_LPUNet 
						and l2.IsAdvance=l1.IsAdvance and l2.ID_LPUContract=l1.ID_LPUContract and l2.ID_LPUAccessKind=l1.ID_LPUAccessKind and l2.Date>l1.date and l2.cd<=l1.cd)
	-- вычищаем мусор старого алгоритма, котороый мог оставить пачку одинаковых _неперекрытых_ писем, поэтому надо оставить последнее по дате формирования
	update l1 set future=-2 --delete l1 --declare @date datetime = '20230808'; select *
	from #letters l1 where cd<convert(date,@date) and 
			exists(select 1 from #letters l2 where l1.ID_ContractPolicy=l2.ID_ContractPolicy and l2.ID_LPUDepartment=l1.ID_LPUDepartment and l2.ID_LPUNet=l1.ID_LPUNet 
						and l2.IsAdvance=l1.IsAdvance and l2.ID_LPUContract=l1.ID_LPUContract and l2.ID_LPUAccessKind=l1.ID_LPUAccessKind and l2.Date>l1.date and l2.cd<=convert(date,@date))-- and l2.date<@date)

	--declare @date datetime = '20230808'
	update p set rn=-1 ----declare convert(date,@date) datetime = '20230808'; select *
	from #pea p 
	where Enddate<convert(date,@date) and rn!=-1
	
	update p set rn=0 ----declare @date datetime = '20230808'; select *
	from #pea p 
	where Enddate>=convert(date,@date) and rn!=0
end
else
begin
	-- удаляем ставшие неактуальными старые письма, т.е. такие, которые переопределили изменение ранее определённого состояния (l2.Date>l1.date and l2.cd<=l1.cd)
	delete l1 --select *
	from #letters l1 where exists(select 1 from #letters l2 where l1.ID_ContractPolicy=l2.ID_ContractPolicy and l2.ID_LPUDepartment=l1.ID_LPUDepartment and l2.ID_LPUNet=l1.ID_LPUNet 
						and l2.IsAdvance=l1.IsAdvance and l2.ID_LPUContract=l1.ID_LPUContract and l2.ID_LPUAccessKind=l1.ID_LPUAccessKind and l2.Date>l1.date and l2.cd<=l1.cd)
	-- вычищаем мусор старого алгоритма, котороый мог оставить пачку одинаковых _неперекрытых_ писем, поэтому надо оставить последнее по дате формирования --declare @date datetime = getdate()
	delete l1 --declare @date datetime = getdate(); select *
	from #letters l1 where cd<convert(date,@date) and --ldcode='757-57' and
			exists(select 1 from #letters l2 where l1.ID_ContractPolicy=l2.ID_ContractPolicy and l2.ID_LPUDepartment=l1.ID_LPUDepartment and l2.ID_LPUNet=l1.ID_LPUNet 
						and l2.IsAdvance=l1.IsAdvance and l2.ID_LPUContract=l1.ID_LPUContract and l2.ID_LPUAccessKind=l1.ID_LPUAccessKind and l2.Date>l1.date and l2.cd<convert(date,@date))-- and l2.date<@date)

	
	delete p  ----declare @date datetime = '20230808'; select *
	from #pea p 
	where Enddate<convert(date,@date) 

	update p set rn=0 ----declare @date datetime = '20230808'; select *
	from #pea p 
	where Enddate>=convert(date,@date) and rn!=0
end
--*/

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#Letters delete overlapped',@rc, null)

print convert(varchar,getdate(),108) + '	Собрали старые письма'
--select * from #pea where ID_ContractPolicy='10EED72E-4F4C-43E5-A1D8-A4ABF3BE16CA' and ID_LPUDeptSend='5CD42654-066F-4AE2-9C94-B83094A0D206' order by IsPrepaid,StartDate
--delete #Letters where Future not in (0,1,2)
--select * from #Letters order by ldcode --where ID_ContractPolicy='10EED72E-4F4C-43E5-A1D8-A4ABF3BE16CA' 
--select * from #pea


------------------------------------------------------------------------------------------------------------
-- Формируем новые письма
------------------------------------------------------------------------------------------------------------

/*
	Тут надо пояснить, что точкой во времени для формирования письма является либо переключение ВП/ФП/АП в #pea, либо ранее посланное (Date<@date) 
	письмо, которое с текущим рассчётным состоянием в #pea может и не совпадать и должно быть перепослано.
*/

-- создаём табличку для получения даты очередного эвента и начинаем шмандыферить нашу цепочку
if object_id('tempdb.dbo.#events')!=0 
	drop table #events
create table #events (h uniqueidentifier, n uniqueidentifier,d uniqueidentifier,p uniqueidentifier,a tinyint ,k uniqueidentifier,c uniqueidentifier,m datetime, i int)
create clustered index event_idx on #events(h,n,d,p,a,k,c,m)
create index event_id_idx on #events(i)

-- создаём табличку для замены договора - для процедурры удаления, того что не поеменялось
if object_id('tempdb.dbo.#changes')!=0 
	drop table #changes
create table #changes (h uniqueidentifier, p uniqueidentifier, n uniqueidentifier, d uniqueidentifier, k uniqueidentifier, 	aid varchar(1000), fact varchar(1000),
					c1 uniqueidentifier, c0 uniqueidentifier, l1 uniqueidentifier, l0 uniqueidentifier)

create clustered index change_idx on #changes(h,n,d,p,k)

-- создаём табличку для замены договора - для смены договора в существующих письмах
if object_id('tempdb.dbo.#lChgContr')!=0 
	drop table #lChgContr
create table #lChgContr (lpuhash uniqueidentifier, rn int, oldContr uniqueidentifier, peaContr uniqueidentifier, letterId uniqueidentifier, step int)

create clustered index hash_idx on #lChgContr(lpuHash)


-- работаем до тех пор, пока есть события, но не погружаемся глубоко в будущее, дажи в гипотетической ситуации, 
-- когда мы это будущее знаем. Впрочем, представить себе в рамках существующего БП @step>2 я не могу. Т.е. РГС может
-- менять-тасовать программы в договорах, оторые старуют через месяц, но дата старта вряд ли будет меняться. И уж
-- тем более не будут строить цепочку изменений ВП на ближайший год-два. Но схема данных это сделать позволяет, так что 
-- предусмотрим эту возможность

--select id_lpucontract, * from #letters  order by ldcode
--select * from #pea
--declare @date datetime = '20230808'


declare @step tinyint=0
declare @daysForward int=isnull(@letterDaysForward,21),		-- за сколько дней до ближайшего события послыать письмо (макс). Т.е. про прикреп с 01/05 письмо будет послано не ранее 09/04.
		@dayLimit int = isnull(@LetterDayLimit,3),			-- за сколько дней до "через одного(два,три...) события" посылать письмо. 
															-- Пример: прикрепили с завтрашнего дня полис, к программе, которая послепослезатвра изменится (мы это видим) - фомируем два письма (на замену и 
															--		на прикреп) в одну сессию.
															--		А если замена программы произойдёт через неделю, то пошлём письмо с заменой при следующем запуске генератора (в случае автомата - на 
															--		след день) или вообще за @dayLimit дней до события, если @checkExisting = 1
		@checkExisting tinyint = isnull(@LetterCheckExisting,1)	-- Не посылать письмо в будущее, если уже есть письмо про будущее:
															--	0: Проверять только "в будущие" письма, созданные в текущую сессию
															--	1: Проверять все письма, включая существующие на момент запуска
															--	2: Вообще ничего не проверять, т.е. посылать все события, видимые впереди. @dayLimit при этом теряет смысл.

--declare @step tinyint=0, @date datetime = getdate(), @daysForward int=5000, @dayLimit int = 5000, @id_session uniqueidentifier, @deletePrevLetters int = 2, @checkexisting int=2, @rc int, @GenCurrentState tinyint, @IsNotDuplicate tinyint,@ExpirationPeriod tinyint
if object_id('tempdb.dbo.#evFull')!=0 
	drop table #evFull

select h,n,d,p,a,k,c, case when m<convert(date,@date) then convert(date,@date) else m end m, 0 r
	, identity(int,1,1) i into #evFull
from (
		--declare @step tinyint=0, @date datetime = '20230808', @daysForward int=2100, @dayLimit int = 3000, @id_session uniqueidentifier, @deletePrevLetters int =0, @checkexisting int=1, @rc int
		select lpuHash h, ID_LPUNet n,ID_LPUDepartment d, ID_ContractPolicy p, IsAdvance a, ID_LPUAccessKind k, ID_LPUContract c, min(CD) m from #letters  
		where future!=-2 and cd<convert(date,@date+@daysForward)
		group by lpuHash, ID_LPUNet, ID_LPUDepartment, ID_ContractPolicy, IsAdvance, ID_LPUAccessKind, ID_LPUContract,importtype 
		union all
		--declare @step tinyint=0, @date datetime = '20230808', @daysForward int=2100, @dayLimit int = 3000, @id_session uniqueidentifier, @deletePrevLetters int =0, @checkexisting int=1, @rc int
		select lpuHash h, ID_LPUNet n,ID_LPUDepartment d, ID_ContractPolicy p, IsAdvance a, ID_LPUAccessKind k, ID_LPUContract c, min(DetachDate+1) m from #letters 
		where future!=-2 and ImportType!=1 and DetachDate+1<convert(date,@date+@daysForward)
		group by lpuHash, ID_LPUNet, ID_LPUDepartment, ID_ContractPolicy, IsAdvance, ID_LPUAccessKind, ID_LPUContract 
		union all
		--declare @step tinyint=0, @date datetime = '20230808', @daysForward int=2100, @dayLimit int = 3000, @id_session uniqueidentifier, @deletePrevLetters int =0, @checkexisting int=1, @rc int
		select lpuHash h, ID_LPUNet n,ID_LPUDeptSend d, ID_ContractPolicy p, IsPrepaid a, ID_LPUAccessKind k, ID_LPUContract c, 
			/*min*/(StartDate) m -- 20231217 Внимание! Этим min я убил цепочки событий!!!
		from #pea 
		where rn=0 and StartDate<convert(date,@date+@daysForward)
		--group by lpuHash, ID_LPUNet, ID_LPUDeptSend, ID_ContractPolicy, IsPrepaid, ID_LPUAccessKind, ID_LPUContract 
		union all
		--declare @step tinyint=0, @date datetime = '20230808', @daysForward int=2100, @dayLimit int = 3000, @id_session uniqueidentifier, @deletePrevLetters int =0, @checkexisting int=1, @rc int
		select lpuHash h, ID_LPUNet n,ID_LPUDeptSend d, ID_ContractPolicy p, IsPrepaid a, ID_LPUAccessKind k, ID_LPUContract c, min(EndDate+1) m from #pea
		where rn=0 and StartDate<convert(date,@date+@daysForward)
		group by lpuHash, ID_LPUNet, ID_LPUDeptSend, ID_ContractPolicy, IsPrepaid, ID_LPUAccessKind, ID_LPUContract 
		union all
		--declare @step tinyint=0, @date datetime = '20230808', @daysForward int=2100, @dayLimit int = 3000, @id_session uniqueidentifier, @deletePrevLetters int =0, @checkexisting int=1, @rc int
		select lpuHash h, ID_LPUNet n,ID_LPUDeptSend d, ID_ContractPolicy p, IsPrepaid a, ID_LPUAccessKind k, ID_LPUContract c, min(EndDate) m from #pea 
		where rn=0 and StartDate<convert(date,@date+@daysForward) and ID_LPUContract=dbo.EmptyUID(null)
		group by lpuHash, ID_LPUNet, ID_LPUDeptSend, ID_ContractPolicy, IsPrepaid, ID_LPUAccessKind, ID_LPUContract 
	) m
group by h,n,d,p,a,k,c,case when m<convert(date,@date) then convert(date,@date) else m end

delete  --select * from
#evFull where m > @date and isnull(@GenCurrentState,0)&3=1-- если при сверке отказались от будущих событий (последние биты - 01), то выкидываем их из рассмотрения в цикле

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#evFull',@rc, null)
 
create clustered index evFull_idx on #evFull(h,n,d,p,a,k,c,m)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#evFull index',null, null)
/*
select d.ID_SubjectLPU,d.code,* from #evFull e, LPUDepartment d where d.id=d order by m,d.code
select IsForLetters, * from LPUContract where ID_SubjectLPU='4B06A079-0CA4-4439-9AC0-DF8D0439F3FC' and ID_Parent is null and IsDirectAccess=1 and isnull(ProlongationType,0)=0 
*/
/*
select * from #events where d='5CD42654-066F-4AE2-9C94-B83094A0D206'
select * from #evFull where h='6F9E3022-1490-9286-22AE-28E121206471' order by m
select * from #pea where lpuhash='6F9E3022-1490-9286-22AE-28E121206471'
select AttachDate, DetachDate,* from #Letters where lpuhash='6F9E3022-1490-9286-22AE-28E121206471'
select * from #fh
select * from #letters
--*/

/*
declare @step tinyint=0, @date datetime = getdate(), @checkExisting tinyint = 1, @daysForward int=2100, @dayLimit int = 3000, @deletePrevLetters tinyint = 0, @rc int, @id_session uniqueidentifier, 
	@SPType int , @GenCurrentState tinyint=3,
	@ID_Signing uniqueidentifier ='5B61FCBD-2097-4DC9-BC32-4F471C9C885C',@ID_Responsible uniqueidentifier = 'BF6C4485-174B-4E9C-9F14-32B7DF8F26DD'--*/
if isnull(@GenCurrentState,0)&1=1
begin
	set @checkExisting = 0
	set @dayLimit=0
end
--select @checkExisting 
while @step<=14			-- В целом вместо 4 можно использовать @dayLimit, хотя при ручных вызовах возможны варианты
		and isnull(@SPType,255)!=4	-- бегать в этом цикле если нам заказали только "изменение данных застрахованных" не надо
begin 
	print '		Event analysis. Step: ' + convert(varchar,@step)
	--declare @step tinyint=1, @date datetime = '20230808', @checkExisting tinyint = 1, @daysForward int=21, @dayLimit int = 0, @deletePrevLetters tinyint = 0, @rc int, @id_session uniqueidentifier
	truncate table #events
	-- Выбираем первое по дате событие. При первом проходе оно может быть в прошлом, но только при первом! (см. предыдущие два апдейта)
	insert #events (h,n,d,p,a,k,c,m,i)
	--declare @step tinyint=1, @date datetime = getdate(),  @GenCurrentState tinyint, @checkExisting tinyint = 1, @daysForward int=2100, @dayLimit int = 3000, @deletePrevLetters tinyint = 0, @rc int, @id_session uniqueidentifier
	select e.h, e.n,e.d,e.p,e.a,e.k,e.c,e.m,e.i from #evfull e,(select h,n,d,p,a,k,c,min(m) m from #evFull group by h,n,d,p,a,k,c) m
	where e.h=m.h and e.c=m.c and e.m=m.m
		and e.n=m.n and e.d=m.d and e.p=m.p and e.a=m.a and e.k=m.k 
	-- если мы в ЛПУ что-то уже послали (подготовили к посылке), то не будем трахать мозг медикам и остановимся
	and (not exists(select 1 from #Letters l where ID_LPUNet=e.n and ID_LPUDepartment=e.d and ID_ContractPolicy=e.p and IsAdvance=e.a and ID_LPUAccessKind=e.k 
					and ID_LPUContract=e.c and (cd>convert(date,@date) or isnull(@GenCurrentState,0)&1=1) and (Tp!='' or @checkExisting=1) and @checkExisting!=2) 
		or (@checkExisting=2 and isnull(@GenCurrentState,0)&1=0)
		or e.m < convert(date,@date + @dayLimit))	-- Но!!! Если до события меньше указанного кол-ва дней, то всё же пошлём, чтобы ребята в ЛПУ загодя подкрутили свои БД

	set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#events step '+convert(varchar,@Step),@rc, null)

	if not exists(select 1 from #events) -- эвенты закончились? Выходим!
		break
--break ; end ; select * from #events -- TODO!!!!! Если что не работает, проверь тут. ДОЛЖЕН СТОЯТЬ КОММЕНТАРИЙ!!!!

	--20231211 Добавил загадочный кусок в цикл расчёта писем, который на лету подставляет новые договоры в старые письма. -->
	--declare @step int = 0
	insert #lChgContr
	--declare @step int = 0
	select lpuHash, rn, max(oldContr) oldContr, max(peaContr) peaContr, max(id) id, @step
	from (
		select isnull(l.lpuHash, p.lpuHash) lpuHash, case when p.ID_LPUContract is null
									then ROW_NUMBER() over (partition by isnull(l.lpuHash, p.lpuHash) order by l.newFact, l.newAdv, l.newAid)	--l.id_lpucontract) --
									else ROW_NUMBER() over (partition by isnull(l.lpuHash, p.lpuHash) order by p.Fact, p.Adv, p.Aid)			--p.id_lpucontract) --
						end rn,
			l.ID_LPUContract oldContr, p.ID_LPUContract peaContr, l.id
		from (select l.* from #letters l,#events e where e.m between l.AttachDate and l.DetachDate and ImportType in (0,2) and l.lpuHash=e.h and e.c=l.ID_LPUContract and future!=-2) l  
		full join (select p.* from #pea p, #events e where e.m between p.StartDate and p.EndDate and p.pEnd='' and p.lpuHash=h and p.ID_LPUContract=c) p on p.lpuHash=l.lpuHash and p.ID_LPUContract=l.ID_LPUContract
		where l.id_lpucontract is null or p.id_lpucontract is null
	) c
	group by lpuHash, rn  having  max(oldContr) is not null and max(peaContr) is not null and max(id) is not null
	order by 1,2

	update lu set ID_LPUContract = dbo.emptyUID(lc.peaContr) --select pe.ID_LPUContract, l.*
	from #lChgContr lc 
	join #Letters lu on lu.id = lc.letterId and lu.tp=''
	where lc.step=@step
	
	if @@ROWCOUNT>0			-- TODO: А надо ли???
	begin
		if (select count(distinct id_contractpolicy) from #pea p)<5 and isnull(@deletePrevLetters,2)<2
			-- удаляем ставшие неактуальными старые письма, т.е. такие, которые переопределили изменение ранее определённого состояния (l2.Date>l1.date and l2.cd<=l1.cd)
			update l1 set future=-2 --delete l1 --declare @date datetime = '20230808'; select *
			from #letters l1 where cd<convert(date,@date) and 
					exists(select 1 from #letters l2 where l1.ID_ContractPolicy=l2.ID_ContractPolicy and l2.ID_LPUDepartment=l1.ID_LPUDepartment and l2.ID_LPUNet=l1.ID_LPUNet 
								and l2.IsAdvance=l1.IsAdvance and l2.ID_LPUContract=l1.ID_LPUContract and l2.ID_LPUAccessKind=l1.ID_LPUAccessKind and l2.Date>l1.date and l2.cd<=convert(date,@date))-- and l2.date<@date)
		else
		-- удаляем ставшие неактуальными старые письма, т.е. такие, которые переопределили изменение ранее определённого состояния (l2.Date>l1.date and l2.cd<=l1.cd)
			delete l1 --declare @date datetime = getdate(); select *
			from #letters l1 where cd<convert(date,@date) and --ldcode='757-57' and
					exists(select 1 from #letters l2 where l1.ID_ContractPolicy=l2.ID_ContractPolicy and l2.ID_LPUDepartment=l1.ID_LPUDepartment and l2.ID_LPUNet=l1.ID_LPUNet 
								and l2.IsAdvance=l1.IsAdvance and l2.ID_LPUContract=l1.ID_LPUContract and l2.ID_LPUAccessKind=l1.ID_LPUAccessKind and l2.Date>l1.date and l2.cd<convert(date,@date))-- and l2.date<@date)
	end
	--20231211 Добавил загадочный кусок в цикл расчёта писем, который на лету подставляет новые договоры в старые письма. <--

	-- На дату соытия вытаскиваем наборы ВП/ФП/АП из последнего письма (#Lettes) и из договора страхования (#pea)
	-- Если они не совпадают формируем письмо, приводящее ЛПУ в состояние, описанное в БД
	
	--declare @date datetime = '20230808',@step int=1, @ID_Signing uniqueidentifier ='5B61FCBD-2097-4DC9-BC32-4F471C9C885C',@ID_Responsible uniqueidentifier = 'BF6C4485-174B-4E9C-9F14-32B7DF8F26DD'
	insert #Letters 
	--declare @date datetime = '20230808',@step int=1, @ID_Signing uniqueidentifier ='5B61FCBD-2097-4DC9-BC32-4F471C9C885C',@ID_Responsible uniqueidentifier = 'BF6C4485-174B-4E9C-9F14-32B7DF8F26DD'
	select tp, null, deptcode, case ImportType when 1 then detachdate+1 else AttachDate end  CD, -1 future, newid(), 
		ID_SubjectLPU, ID_LPUNet, ID_LPUDeptSend, @date, ImportType, id_lpucontract, ID_LPUAccessKind, isPrepaid, ID_ContractPolicy, 
		AttachDate,detachdate, 1,
		isRetail, aid, adv, fact, naid, nadv, nfact, 
		0 isKS, @ID_Responsible ID_Responsible, @ID_Signing ID_Signing,
		lpuHash
	from (
	--declare @date datetime = '20230808',@step int=1, @ID_Signing uniqueidentifier ='5B61FCBD-2097-4DC9-BC32-4F471C9C885C',@ID_Responsible uniqueidentifier = 'BF6C4485-174B-4E9C-9F14-32B7DF8F26DD'
	select '0'+convert(varchar,@step) Tp, p.lpuHash,
		isnull(p.DeptCode, l.ldCode) deptcode, 
		isnull(p.ID_LPU,l.ID_SubjectLPU) ID_SubjectLPU, n ID_LPUNet, m.d ID_LPUDeptSend, 
		case isnull(p.pend,'Emp') when 'Emp' then 1 else case isnull(l.importtype,1) when 1 then 0 else 2 end end ImportType, 
		c id_lpucontract, k ID_LPUAccessKind, a isPrepaid, p ID_ContractPolicy, 
		case isnull(p.pend,'Emp') when 'Emp' then isnull(l.AttachDate, m) -- для открепа берём дату аттача из текущего активного письма
					-- А вот с прикрепом всё погаже. Берём последнее письмо (CD<=m) и, если это прикреп(замена) смотрим, какая у него дата открепа.
					-- Если дата открепа больше m, то мы имеем дело с текущим письмом (pl.id=l.id) и значит делаем замену со StartDate
					-- Если дата открепа меньше m, то мы имеем дело с завершившейся программой (текущего письма нет - l.id is null), а значит старуем новую 
					--		либо с момнтеа окончания предыдущей, либо со StartDate, если она больше предыдущего DetachDate
			else case when lp.ImportType in (0,2) and lp.DetachDate<m and lp.DetachDate>p.StartDate then lp.DetachDate+1 else 
				case when l.ImportType=1 and l.DetachDate>isnull(p.startdate,m) then l.DetachDate+1 else isnull(p.startdate,m) end end
		end AttachDate, 
		case isnull(p.pend,'No') when 'No' then isnull(l.AttachDate-1,m-1) when 'Emp' then isnull(p.StartDate-1,m-1) else p.progEnd end detachdate, 
		isnull(p.isretail,l.IsRetail) isRetail, 
		isnull(p.aid,'') aid, isnull(p.adv,'') adv, isnull(p.fact,'') fact, 
		isnull(l.newAid,'') naid, isnull(l.newAdv,'') nadv, isnull(l.newFact,'') nfact
	/*--declare @date datetime = '20230808',@step int=1, @ID_Signing uniqueidentifier ='5B61FCBD-2097-4DC9-BC32-4F471C9C885C',@ID_Responsible uniqueidentifier = 'BF6C4485-174B-4E9C-9F14-32B7DF8F26DD'
	select case isnull(p.pend,'Emp') when 'Emp' then isnull(l.AttachDate, m)
			else case when lp.ImportType in (0,2) and lp.DetachDate<m and lp.DetachDate>p.StartDate then lp.DetachDate+1 else isnull(p.startdate,m) end
		end AttachDate,* --*/
	--declare @date datetime = '20230808',@step int=1, @ID_Signing uniqueidentifier ='5B61FCBD-2097-4DC9-BC32-4F471C9C885C',@ID_Responsible uniqueidentifier = 'BF6C4485-174B-4E9C-9F14-32B7DF8F26DD' select m.*,p.*
	from #events m
	-- текущее состояние ВП/ФП/АП по письмам
	outer apply (select top 1 * from #Letters 
				where ID_LPUNet=n and ID_LPUDepartment=d and ID_ContractPolicy=p and IsAdvance=a and ID_LPUAccessKind=k and ID_LPUContract=c 
					and CD<=m and (m between AttachDate and DetachDate or Importtype=1) and future!=-2 order by cd desc) l
	-- текущее состояние ВП/ФП/АП по БД
	outer apply (select top 1 * from #pea 
				where ID_LPUNet=n and ID_LPUDeptSend=d and ID_ContractPolicy=p and IsPrepaid=a and ID_LPUAccessKind=k and ID_LPUContract=c 
					and m between StartDate and Enddate order by StartDate desc) p
	-- следующее состояние ВП/ФП/АП по БД
	-- TODO: Если скажут 
	-- outer apply (select top 1 * from #pea where ID_LPUNet=n and ID_LPUDeptSend=d and ID_ContractPolicy=p and IsPrepaid=a and ID_LPUAccessKind=k and ID_LPUContract=c and StartDate > m order by StartDate) np
	-- предыдущее состояние ВП/ФП/АП по письмам
	outer apply (select top 1 * from #Letters 
				where ID_LPUNet=n and ID_LPUDepartment=d and ID_ContractPolicy=p and IsAdvance=a and ID_LPUAccessKind=k and ID_LPUContract=c 
					and CD<=m and future!=-2 order by cd desc) lp
	where (isnull(l.newaid,'')!=isnull(p.aid,'') or isnull(l.newadv,'')!=isnull(p.adv,'') or isnull(l.newfact,'')!=isnull(p.fact,'')) -- Если они не совпадаю формируем письмо
	) nl

	set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#Letters add step '+convert(varchar,@Step),@rc, null)
	
	--break ; end select * from #letters select * from #events -- TODO!!!!! Если что не работает, проверь тут. ДОЛЖЕН СТОЯТЬ КОММЕНТАРИЙ!!!!

	-- Замену договора обработать тут. Напоминаю, что необходимо выловить неавансовые писма с одинаковыми ВП/ФП, но разными договорами ЛПУ
	--		в найденом взять новый договор и проапдейтить последний LPULetterFlow по которому собираемся сделать откреп, ну и #Letters по полису/лпу/вп/фп 
	--		тоже проапдейтить. После удалить найденные пары из #Letters 

	set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#Letters del overlapped step '+convert(varchar,@Step),@rc, null)

	truncate table #changes
	
	-- Смена договора ЛПУ. Собрали пары из свежесозданного и последнего писем с разными договорами ЛПУ, но одинаковыми наборами ФП и ВП и грохнули их -->
	insert #changes (h,p,n,d,k,aid,fact,c1,c0,l1,l0)
	select l1.lpuHash, l1.ID_ContractPolicy, l1.ID_LPUNet, l1.ID_LPUDepartment, l1.ID_LPUAccessKind, l0.newaid, l0.newfact, l1.ID_LPUContract, l0.ID_LPUContract, l1.ID, l0.id
	--	,l1.date, l0.date, l1.ImportType, l0.ImportType, l1.tp, l0.tp
	from #letters l1	-- это письмо со старым договором, от которого должен был бы быть откреп
	join #letters l0	-- это с новым, к которому надо было бы прикрепиться
			on l1.lpuHash=l0.lpuHash and l1.ID_LPUContract!=l0.ID_LPUContract 
			and l1.ID_ContractPolicy=l0.ID_ContractPolicy and l1.ID_LPUAccessKind=l0.ID_LPUAccessKind and l1.ID_LPUDepartment=l0.ID_LPUDepartment and l1.ID_LPUNet=l0.ID_LPUNet
			and l0.newaid=l1.oldAid and l0.newfact=l1.oldFact and l0.IsAdvance=0 and l0.ImportType=0 --and l0.Tp!=''
	where l1.ImportType=1 and l1.IsAdvance=0 --and l1.tp!='' 

	--break
	set @rc=@@rowcount 
	if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#changes contract swap step '+convert(varchar,@Step),@rc, null)

	if @rc > 0
	begin
		-- Меняем договора в #letters. Тотально по базовому ключу
		update l set ID_LPUContract=c0
		--select *
		from #Letters l
		join #changes c on l.ID_ContractPolicy=p and l.ID_LPUAccessKind=k and l.ID_LPUDepartment=d and l.ID_LPUNet=n and l.ID_LPUContract=c1 
			and l.IsAdvance=0 --and l.newfact=fact and l.newaid=aid 
		-- 20231202 Теперь меняем все включения сторого догововра на новый, чтобы старый более и не отсвечивал, раз заменили <--


		-- удаляем замены договора (откреп от старого и прикреп к новому) из #Letters
		-- 20231202 Теперь не удаляем. Пусть остаются для того, чтобы видеть прикреп к новому дог.ЛПУ ("замена договора"), тогда последующие открепы/замены 
		--			останутся открепами/заменами, только от нового уже договора
		update l set tp='' --delete l --select * 
		from #letters l where ID in (select l0 from #changes union all select l1 from #changes) and tp!=''

		set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#changes: swaps deleted',@rc, null)

	end
	-- Смена договора ЛПУ. Собрали пары из свежесозданного и последнего писем с разными договорами ЛПУ, но одинаковыми наборами ФП и ВП и грохнули их <--

	if (select count(distinct id_contractpolicy) from #pea p)<5 and isnull(@deletePrevLetters,2)<2
		-- удаляем ставшие неактуальными старые письма, т.е. такие, которые переопределили изменение ранее определённого состояния (l2.Date>l1.date and l2.cd<=l1.cd)
		update l1 set future=-2 --delete l1 -- В боевой версии можно делать delete. В тестовой ничего не удаляю, чтобы красивые даграммы были в отладошном экселе
		--select *
		from #letters l1 where exists(select * from #letters l2 where l2.ID_ContractPolicy=l1.ID_ContractPolicy and l2.ID_LPUDepartment=l1.ID_LPUDepartment and l2.ID_LPUNet=l1.ID_LPUNet 
						and l2.IsAdvance=l1.IsAdvance and l2.ID_LPUContract=l1.ID_LPUContract and l2.ID_LPUAccessKind=l1.ID_LPUAccessKind and l2.Date>l1.date and l2.cd<=l1.cd)
	else
	-- удаляем ставшие неактуальными старые письма, т.е. такие, которые переопределили изменение ранее определённого состояния (l2.Date>l1.date and l2.cd<=l1.cd)
		delete l1 -- В боевой версии можно делать delete. В тестовой ничего не удаляю, чтобы красивые даграммы были в отладошном экселе
		from #letters l1 where exists(select * from #letters l2 where l2.ID_ContractPolicy=l1.ID_ContractPolicy and l2.ID_LPUDepartment=l1.ID_LPUDepartment and l2.ID_LPUNet=l1.ID_LPUNet 
						and l2.IsAdvance=l1.IsAdvance and l2.ID_LPUContract=l1.ID_LPUContract and l2.ID_LPUAccessKind=l1.ID_LPUAccessKind and l2.Date>l1.date and l2.cd<=l1.cd)
		
	-- убираем из #evFull обработанные даты
	delete f from #evFull f, #events e where f.i=e.i

	-- вуа-ля!
	
	set @step=@step+1
	--break; end                             -- TODO!!!!! Если что не работает, проверь тут. ДОЛЖЕН СТОЯТЬ КОММЕНТАРИЙ!!!!
end

--select c0,* from #changes
--select * from #Letters 
--select * from #pcl
--select * from #pea
--

print convert(varchar,getdate(),108) + '	Собрали то, что будем в эту сессию посылать'

-- Подчистим сгенерированное, если @SType указан и не равен 4
--declare @sptype int 
if @SPType!=4
begin

delete ld --select ld.* 
from #Letters ld where ld.Tp!='' and (ld.ImportType!=@SPType or		-- все новые письма с не тем типом
	-- или те, у которых есть предыдущие новые письма с не тем типом. Т.е. при @SPType=2 цепочку из двух замен пошлём, а откреп и прикреп к другим ВП через два дня - нет
	exists(select 1 from #Letters lp where lp.cd<=ld.cd and lp.ImportType!=@SPType and lp.Tp!=''
				and ld.ID_ContractPolicy=lp.ID_ContractPolicy and ld.ID_LPUDepartment=lp.ID_LPUDepartment and ld.ID_LPUNet=lp.ID_LPUNet 
				and ld.IsAdvance=lp.IsAdvance and ld.ID_LPUContract=lp.ID_LPUContract and ld.ID_LPUAccessKind=lp.ID_LPUAccessKind))
end

-------------------------------------------------------------------
-- Добавляем изменение параметров застрахованных
-------------------------------------------------------------------
--select @SPType, isnull(@SPType,4),@GenCurrentState,isnull(@GenCurrentState,1),isnull(@GenCurrentState,1)&1,@ErrCorrections
if isnull(@SPType,4)=4 and isnull(@GenCurrentState,0)&1!=1 and @ErrCorrections is null
begin
--declare @date datetime = '20230808'	

	print convert(varchar,getdate(),108) + '	Начали письма на замену данных'

	insert #Letters
	/*
	declare @step tinyint=0, @date datetime = getdate(), @checkExisting tinyint = 1, @daysForward int=2100, @dayLimit int = 3000, @deletePrevLetters tinyint = 0, @rc int, @id_session uniqueidentifier, 
	@SPType int , @GenCurrentState tinyint=3,
	@ID_Signing uniqueidentifier ='5B61FCBD-2097-4DC9-BC32-4F471C9C885C',@ID_Responsible uniqueidentifier = 'BF6C4485-174B-4E9C-9F14-32B7DF8F26DD'--*/
	select '44' Tp,
		null, ldcode,
		convert(date,@date) CD,
		--s.FullName,f.FullName,isnull(sp.Gender,10),isnull(f.Gender,10),sp.BirthDay,f.BirthDate,isnull(ps.FullName,''),isnull(f.ParentName,''),
		-44 future, newid(), dbo.EmptyUID(id_lpu), dbo.EmptyUID(f.ID_LPUNet), dbo.EmptyUID(f.dept), @date, 
		4 ImportType, 
		dbo.EmptyUID(f.id_lpucontract), f.ID_LPUAccessKind, 0 isPrepaid, f.ID_ContractPolicy, 
		f.AttachDate, f.detachdate, 
		1, f.IsRetail, 
		'', '', '', '', '', '',0, @ID_Responsible ID_Responsible, @ID_Signing ID_Signing,
		dbo.LPULetterKeyHash(ID_ContractPolicy,f.dept,ID_LPUAccessKind,ID_LPUNet,ID_LPU,0) lpuHash
	from (--declare @date datetime = getdate()	
		select */*ldcode, 
		s.FullName,f.FullName,isnull(sp.Gender,10),isnull(f.Gender,10),sp.BirthDay,f.BirthDate,isnull(ps.FullName,''),isnull(f.ParentName,''),
		f.ID_SubjectLPU, f.ID_LPUNet, f.ID_LPUDepartment, f.id_lpucontract, f.ID_LPUAccessKind, f.ID_ContractPolicy, 
		f.AttachDate, f.detachdate, f.IsRetail*/
		from #pcl pli
		join (select id_contractpolicy pol, lf.ID_SubjectLPU lpu, ID_LPUNet net, ID_LPUDepartment dept, ld.Code ldCode from LPULetterFlow lf, LPUDepartment ld where ld.id=lf.ID_LPUDepartment
				group by id_contractpolicy, lf.ID_SubjectLPU, ID_LPUNet, ID_LPUDepartment, ld.Code) d
					on d.pol = pli.ID_ContractPolicy and (d.lpu=pli.ID_LPU or d.net=pli.ID_LPUNet) 
		cross apply (select top 1 Importtype, FullName, ParentName, Gender,BirthDate, ID_LPUContract, ID_LPUAccessKind, attachdate, detachdate,isretail
					from LPULetterFlow lf (nolock) 
					where lf.ID_ContractPolicy = pli.ID_ContractPolicy and ((lf.ID_SubjectLPU=pli.ID_LPU and lf.ID_LPUDepartment=d.dept) or (lf.ID_LPUNet=pli.ID_LPUNet and ID_SubjectLPU is null))
						and Date<=@date and ((DetachDate >= convert(date,@date) and ImportType!=4) or ImportType = 4) order by date desc) f 
		cross apply (select s.fullname s_fullname, s.BirthDay s_BirthDay, s.gender s_gender, s.ParentName s_ParentName 
					from (select id, id_SubjectP from ContractPolicy where id=pli.ID_ContractPolicy  union all select id, id_SubjectP from RetailContractPolicy pr where id=pli.ID_ContractPolicy) p
						join (select s.id, s.fullname, sp.BirthDay, sp.gender, ps.fullname ParentName from SubjectP sp 
								join Subject s on sp.id = s.id
								left join Subject ps on ps.id=sp.ID_Parent) s on s.id = p.ID_SubjectP
					)  s
		where f.ImportType != 1 and (s_FullName!=f.FullName or isnull(s_Gender,10)!=isnull(f.Gender,10) or s_BirthDay!=f.BirthDate or isnull(s_ParentName,'')!=isnull(f.ParentName,'')) 
	) f
	where exists(select * from #pea p where p.ID_ContractPolicy = f.ID_ContractPolicy and (p.ID_LPUDeptSend=f.dept or f.ID_LPUNet=p.ID_LPUNet)
					and Enddate > convert(date,@date)  and (aid!='' or fact!='' or adv!=''))
	
	set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#Letters Importype=4',@rc, null)
	
	print convert(varchar,getdate(),108) + '	Собрали письма на замену данных'
end
-------------------------------------------------------------------
-- Обработка ошибок
-------------------------------------------------------------------

--20231129 Обрабатываем ситуацию открепа от прикрепа/замены по старому, недействующему договору
--20231208 Возвращаю это обратно: если договор сдох, то откреп не нужен
update #Letters set ID_LPUContract=dbo.EmptyUID(null) where tp!='' and ImportType = 1 and ID_LPUContract not in (select id from #lpuc)
														--(select ID from lpucontract where ID_Parent is null and Status in (40,50))


--declare @ID_Responsible uniqueidentifier='0D0E06D3-7733-438B-8197-30FEB2BE66EF'
if object_id('tempdb.dbo.#errors')!=0 
	drop table #errors
	
-- Ошибки поиска договоров: "Нет" и "Много"

select convert(uniqueidentifier,null) ID_Error, ImportType, l.ID ID_LPULetter,
	-- про получателя
	dbo.NullUID(pe.ID_LPU) ID_LPU, dbo.NullUID(l.ID_LPUNet) ID_LPUNet, dbo.NullUID(l.ID_LPUDepartment) ID_LPUDepartment, pe.ID_PriceListItem,
	-- тут данные договра ДМС
	case l.isretail when 0 then pe.ID_Contract end ID_Contract, case l.isretail when 0 then l.ID_ContractPolicy end ID_ContractPolicy, 
	case l.isretail when 0 then pe.ID_ContractProgram end ID_ContractProgram, case l.isretail when 0 then pe.ID_ContractProgramElement end ID_ContractProgramElement,	
	-- тут данные коробки (что их не сложить в те же поля, что и договора ДМС????)
	case l.isretail when 1 then pe.ID_Contract end ID_RetailContract, 
	case l.isretail when 1 then pe.ID_ContractProgram end ID_RetailContractProgram, case l.isretail when 1 then pe.ID_ContractProgramElement end ID_RetailProgramElement,
	-- общее из расчёта письма
	l.IsAdvance, l.ID_LPUAccessKind, l.CD ChangeDate, AttachDate, DetachDate, convert(uniqueidentifier,null) ID_Responsible,
	-- и описание ошибки
	pe.ErrorCode, WrongIDs LPUWrongIDs, pe.LPUContractError+' '+isnull(ldCode,'') ErrorText, 0 IsNightly
into #errors 
--select *
from #Letters l 
--left
join (select isretail,id_contractpolicy, ID_ContractProgram, pe.id_contract, pe.id_lpucontract, case pe.id_lpu when dbo.EmptyUID(null) then pli.ID_LPU else pe.id_lpu end ID_LPU, 
		id_lpudeptsend, pe.id_lpunet, pe.ksStart, pe.ksEnd, StartDate, enddate, progEnd, fhiStart, fhiEnd, FranchiseInterest, fhpStatus,
		IsPrepaid, ID_LPUAccessKind, pe.ID_PriceListItem, ID_ContractProgramElement, pli.ErrorCode, WrongIDs, pli.LPUContractError
		--,pe.AidName, pe.advNum, pe.factCode
		from #pe pe 
		join #plishort pli on pli.ID_Contract=pe.ID_Contract and pli.ID_PriceListItem=pe.ID_PriceListItem 
							and (pli.id_lpunet=dbo.NullUID(pe.ID_LPUNet) or pli.ID_LPU=pe.ID_LPU) and LPUContractError is not null 
							and pli.ksStart=pe.ksStart and pli.ksend=pe.ksEnd 
		where pe.id_lpucontract = dbo.EmptyUID(null)
		group by isretail,ID_ContractProgram,id_contractpolicy, pe.id_contract, pe.id_lpucontract, case pe.id_lpu when dbo.EmptyUID(null) then pli.ID_LPU else pe.id_lpu end, id_lpudeptsend, 
				pe.id_lpunet, pe.ksStart, progEnd, IsPrepaid, ID_LPUAccessKind, pe.ID_PriceListItem, ID_ContractProgramElement, pli.ErrorCode, WrongIDs, pli.LPUContractError, 
				StartDate, enddate, fhiStart, fhiEnd, pe.ksend, FranchiseInterest, fhpStatus
				--,pe.AidName, pe.advNum, pe.factCode
	) pe on pe.ID_ContractPolicy=l.ID_ContractPolicy /*and pe.ksStart=l.AttachDate*/ 
		and ((pe.ID_LPUDeptSend=l.ID_LPUDepartment and l.id_subjectlpu=pe.id_lpu) or (pe.id_lpunet=l.ID_LPUNet and pe.id_lpunet!=dbo.EmptyUID(null)) and l.ID_LPUNet!=dbo.EmptyUID(null))
		and pe.IsPrepaid=l.IsAdvance and pe.ID_LPUAccessKind = l.ID_LPUAccessKind and pe.id_lpucontract=l.ID_LPUContract
				and case importtype when 1 then DetachDate else AttachDate end between pe.ksStart and pe.ksEnd --and p1.StartDate between pp.ksStart and pp.ksEnd
				and not (case importtype when 1 then DetachDate else AttachDate end  between pe.startDate and pe.endDate and FranchiseInterest!=0 and not (case importtype when 1 then DetachDate else AttachDate end  between pe.fhiStart and pe.fhiEnd and fhpStatus=1)) 
				and not (case importtype when 1 then DetachDate else AttachDate end  between pe.fhiStart and pe.fhiEnd and fhpStatus != 1 and FranchiseInterest!=0) 
				and ((FranchiseInterest=0) or (FranchiseInterest!=0 and fhpStatus=1))
		/*and (case ImportType when 0 then l.newAid else oldaid end like '%'+pe.AidName+'%' or 
			case ImportType when 0 then l.newFact else oldfact end like '%'+pe.factCode+'%' or 
			case ImportType when 0 then l.newAdv else l.OldAdv end like '%'+pe.advNum+'%')*/
where l.Tp!='' and ImportType!=4 and l.ID_LPUContract = dbo.EmptyUID(null) --and l.ID_LPUNet='F463DE93-DC73-4BA2-95B9-B8C85254C9BD'
union all select top 0 null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null -- хотим nullable columns по кругу


--select * from #errors where ID_LPUDepartment='2E19E6D2-84CD-406B-BB24-3F407B3F26AF'
--select errorcode, * from #plishort where id_lpu='FDA5867F-D6B7-42DD-B050-136F098744BA' 
--select * from #Letters where id_subjectlpu='FDA5867F-D6B7-42DD-B050-136F098744BA' 
--select * from LPULetterFlow where ID_ContractPolicy='710FCF5D-33B0-4594-A12F-9B80ADA5BDFE'

/*
select * from #pea where ID_LPU='FDA5867F-D6B7-42DD-B050-136F098744BA' 
select * from #Letters where ID_subjectLPU='FDA5867F-D6B7-42DD-B050-136F098744BA'
select errorcode, * from #plishort where  ID_LPU='903DAF0E-5441-4897-9614-3D5B9EA49992'
select errortext,* from #errors where ID_LPU='FDA5867F-D6B7-42DD-B050-136F098744BA'
*/
set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#errors LPUContract',@rc, null)

-- расширяем ошибку "много договоров" на соседние ПЛ, если в них таки договор определеися
-- 20231205 Также расширяем и "нет договоров" на соседние ПЛ, чтобы избежать кривых писем по "недоделанным" программмам

--declare @ID_Responsible uniqueidentifier='0D0E06D3-7733-438B-8197-30FEB2BE66EF'

insert #errors
select convert(uniqueidentifier,null) ID_Error, ImportType, l.ID ID_LPULetter,
	-- про получателя
	dbo.NullUID(l.ID_SubjectLPU) ID_LPU, dbo.NullUID(l.ID_LPUNet) ID_LPUNet, dbo.NullUID(l.ID_LPUDepartment), pe.ID_PriceListItem,
	-- тут данные договра ДМС
	case l.isretail when 0 then isnull(pe.ID_Contract,(select top 1 ID_Contract from ContractPolicy where id=l.ID_ContractPolicy)) end ID_Contract, 
	case l.isretail when 0 then l.ID_ContractPolicy end ID_ContractPolicy, 
	case l.isretail when 0 then pe.ID_ContractProgram end ID_ContractProgram, case l.isretail when 0 then pe.ID_ContractProgramElement end ID_ContractProgramElement,	
	-- тут данные коробки (что их не сложить в те же поля, что и договора ДМС????)
	case l.isretail when 1 then isnull(pe.ID_Contract,(select top 1 ID_RetailContract from RetailContractPolicy where id=l.ID_ContractPolicy))  end ID_RetailContract,
	case l.isretail when 1 then pe.ID_ContractProgram end ID_RetailContractProgram, case l.isretail when 1 then pe.ID_ContractProgramElement end ID_RetailProgramElement,
	-- общее из расчёта письма
	l.IsAdvance, l.ID_LPUAccessKind, l.CD ChangeDate, AttachDate, DetachDate, null ID_Responsible,
	-- и описание ошибки
	-- 20231205 Также расширяем и "нет договоров" на соседние ПЛ -->
	--2 ErrorCode, WrongIDs LPUWrongIDs, 'Существуют ПЛ с "много договоров"'+' '+l.ldCode  ErrorText, 0 IsNightly
	ErrCod ErrorCode, WrongIDs LPUWrongIDs, case ErrCod when 2 then 'Существуют ПЛ с "много договоров"' else 'Существуют ПЛ с "нет договора"' end +' '+l.ldCode  ErrorText, 0 IsNightly
	-- 20231205 Также расширяем и "нет договоров" на соседние ПЛ <--
--select *
from (select l.*, ErrCod from #letters l, 
			(select l.cd, l.ID_Letter, l.ID_ContractPolicy, l.ID_LPUDepartment, ldCode, ErrCod from #letters l, 
						(select ChangeDate, e.ID_LPUDepartment, ID_ContractPolicy, max(e.ErrorCode) ErrCod from #errors e where e.ErrorCode in (2,1) -- =2 
									and e.IsAdvance=0
						group by ChangeDate, e.ID_LPUDepartment, ID_ContractPolicy) e 
			where l.ID_LPUDepartment = e.ID_LPUDepartment and l.IsAdvance = 0 and l.ID_ContractPolicy=e.ID_ContractPolicy
				and l.tp!='' and l.ID_LPUContract=dbo.EmptyUID(null)) le
		where l.ImportType!=4 and le.ID_ContractPolicy=l.ID_ContractPolicy and le.ID_LPUDepartment=l.ID_LPUDepartment and IsAdvance=0 and tp!='' and l.ID_LPUContract!=dbo.EmptyUID(null)-- and le.CD>=l.cd 
	) l 
join (select isretail,id_contractpolicy, ID_ContractProgram, pe.id_contract, pe.id_lpucontract, case pe.id_lpu when dbo.EmptyUID(null) then pli.ID_LPU else pe.id_lpu end ID_LPU, 
		id_lpudeptsend, pe.id_lpunet, pe.ksStart, pe.ksEnd, StartDate, enddate, progEnd, fhiStart, fhiEnd, FranchiseInterest, fhpStatus,
		IsPrepaid, ID_LPUAccessKind, pe.ID_PriceListItem, ID_ContractProgramElement, pli.ErrorCode, WrongIDs, pli.LPUContractError
		from #pe pe 
		join #plishort pli on pli.ID_Contract=pe.ID_Contract and pli.ID_PriceListItem=pe.ID_PriceListItem 
							and (pli.id_lpunet=dbo.NullUID(pe.ID_LPUNet) or pli.ID_LPU=pe.ID_LPU) and (pli.LPUContractError is null or pe.id_lpucontract != dbo.EmptyUID(null))
							and pli.ksStart=pe.ksStart and pli.ksend=pe.ksEnd 
		where pe.id_lpucontract != dbo.EmptyUID(null)
		group by isretail,ID_ContractProgram,id_contractpolicy, pe.id_contract, pe.id_lpucontract, case pe.id_lpu when dbo.EmptyUID(null) then pli.ID_LPU else pe.id_lpu end, id_lpudeptsend, 
				pe.id_lpunet, pe.ksStart, progEnd, IsPrepaid, ID_LPUAccessKind, pe.ID_PriceListItem, ID_ContractProgramElement, pli.ErrorCode, WrongIDs, pli.LPUContractError, 
				StartDate, enddate, fhiStart, fhiEnd, pe.ksend, FranchiseInterest, fhpStatus
				--,pe.AidName, pe.advNum, pe.factCode
	) pe on pe.ID_ContractPolicy=l.ID_ContractPolicy and pe.ksStart=l.AttachDate and pe.ID_LPUDeptSend=l.ID_LPUDepartment and pe.id_lpunet=l.ID_LPUNet and l.id_subjectlpu=pe.id_lpu 
			and pe.IsPrepaid=l.IsAdvance and pe.ID_LPUAccessKind = l.ID_LPUAccessKind
				and case importtype when 1 then DetachDate else AttachDate end between pe.ksStart and pe.ksEnd --and p1.StartDate between pp.ksStart and pp.ksEnd
				and not (case importtype when 1 then DetachDate else AttachDate end  between pe.startDate and pe.endDate and FranchiseInterest!=0 
				and not (case importtype when 1 then DetachDate else AttachDate end  between pe.fhiStart and pe.fhiEnd and fhpStatus=1)) 
				and not (case importtype when 1 then DetachDate else AttachDate end  between pe.fhiStart and pe.fhiEnd and fhpStatus != 1 and FranchiseInterest!=0) 
				and ((FranchiseInterest=0) or (FranchiseInterest!=0 and fhpStatus=1))

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#errors MC extend',@rc, null)

-- Письма также переводим в разряд ошибочных, если есть ошибки "много договоров" в тех же полисах-ТО_ЛПУ(к авансам это не относится)
-- 20231205 Также расширяем и "нет договоров" на соседние ПЛ, чтобы избежать кривых писем по "недоделанным" программмам

update l set ID_LPUContract=dbo.EmptyUID(null) --select l.* 
from #letters l, (select l.cd, l.ID_ContractPolicy, l.ID_LPUDepartment from #letters l, (select e.ID_LPUDepartment, ID_ContractPolicy from #errors e 
					-- 20231205 Также расширяем и "нет договоров" на соседние ПЛ -->
					-- where e.ErrorCode=2 and e.IsAdvance=0) e 
					where e.ErrorCode in (1,2) and e.IsAdvance=0) e 
					-- 20231205 Также расширяем и "нет договоров" на соседние ПЛ <--
			where l.ID_LPUDepartment = e.ID_LPUDepartment and l.IsAdvance = 0 and l.ID_ContractPolicy=e.ID_ContractPolicy
				and l.tp!='' and l.ID_LPUContract=dbo.EmptyUID(null)) le
		where le.ID_ContractPolicy=l.ID_ContractPolicy and le.ID_LPUDepartment=l.ID_LPUDepartment and IsAdvance=0 and tp!='' and l.ID_LPUContract!=dbo.EmptyUID(null) and le.CD=l.cd


-- собираем ошибки ТО ЛПУ (неактивно, не определено)

insert #errors (ID_LPULetter,ImportType, IsAdvance, ChangeDate, AttachDate, DetachDate, ID_LPUAccessKind, 
	ID_Contract, ID_ContractPolicy, ID_ContractProgram, ID_ContractProgramElement, 
	ID_RetailContract, ID_RetailContractProgram, ID_RetailProgramElement, 
	ID_PriceListItem, ID_LPU, ID_LPUDepartment, ErrorCode, ErrorText,IsNightly)
select l.id, ImportType, IsAdvance, CD, AttachDate, DetachDate,  l.ID_LPUAccessKind,
		cp.ID_Contract,  case l.isretail when 0 then l.ID_ContractPolicy end ID_ContractPolicy, case l.isretail when 0 then ID_ContractProgram end ID_ContractProgram , 
		case l.isretail when 0 then ID_ContractProgramElement end ID_ContractProgramElement, 
		rp.ID_RetailContract, case l.isretail when 1 then ID_ContractProgram end ID_RetailContractProgram, 
							case l.isretail when 1 then ID_ContractProgramElement end ID_RetailContractProgramElement, 
		ID_PriceListItem, dbo.NullUID(ID_LPU), dbo.NullUID(ID_LPUDepartment), 4+d.indefinitemain*4 ErrorCode, 
		case d.indefiniteMain when 0 then 'Неактивное ТО ЛПУ '+ d.Code else 'Нет главного ТО ЛПУ '+d.code end ErrorText,0
--select DeptCode, ID_ContractProgramElement, importtype,case importtype when 1 then DetachDate else AttachDate end ccd,pe.ksStart,pe.ksEnd ,fhiStart, fhiEnd, FranchiseInterest, fhpStatus
from #Letters l
join #lpud d on l.ID_LPUDepartment=d.id and (d.IsInactive > 0 or d.indefiniteMain != 0)
left join (select ID_ContractPolicy, ID_LPU, ID_LPUContract, ID_LPUDeptSend, ID_LPUNet, ID_Contract, ID_ContractProgram, ID_ContractProgramElement, ID_PriceListItem,
			ID_LPUAccessKind, IsPrepaid, StartDate, enddate, ksStart, ksEnd, fhiStart, fhiEnd, fhpStatus, FranchiseInterest, DeptCode
		from #pe group by ID_ContractPolicy, ID_LPU, ID_LPUContract, ID_LPUDeptSend, ID_LPUNet, ID_Contract, ID_ContractProgram, ID_ContractProgramElement, ID_PriceListItem,
						ID_LPUAccessKind, IsPrepaid, StartDate, enddate, ksStart, ksEnd, fhiStart, fhiEnd, fhpStatus, FranchiseInterest, DeptCode
	) pe on pe.ID_ContractPolicy=l.ID_ContractPolicy /*and pe.ksStart=l.AttachDate*/ and pe.ID_LPUDeptSend=l.ID_LPUDepartment and pe.id_lpunet=l.ID_LPUNet and l.ID_SubjectLPU=pe.ID_LPU
			and pe.IsPrepaid=l.IsAdvance and pe.ID_LPUAccessKind = l.ID_LPUAccessKind
				and case importtype when 1 then DetachDate else AttachDate end between pe.ksStart and pe.ksEnd --and p1.StartDate between pp.ksStart and pp.ksEnd
				and not (case importtype when 1 then DetachDate else AttachDate end  between pe.startDate and pe.endDate and FranchiseInterest!=0 and not (case importtype when 1 then DetachDate else AttachDate end  between pe.fhiStart and pe.fhiEnd and fhpStatus=1)) 
				and not (case importtype when 1 then DetachDate else AttachDate end  between pe.fhiStart and pe.fhiEnd and fhpStatus != 1 and FranchiseInterest!=0) 
				and ((FranchiseInterest=0) or (FranchiseInterest!=0 and fhpStatus=1))
left join ContractPolicy cp on cp.ID = l.ID_ContractPolicy
left join RetailContractPolicy rp on rp.ID = l.ID_ContractPolicy
where l.Tp!='' and l.ID_LPUNet=dbo.EmptyUID(null) -- для сетей таких ошибок нет
/*group by l.id, l.id_letter, ImportType, IsAdvance, IsNightly, CD, AttachDate, DetachDate,  l.ID_LPUAccessKind,
	cp.ID_Contract,  case l.isretail when 0 then l.ID_ContractPolicy end, rp.ID_RetailContract, 
		ID_PriceListItem, ID_LPU, ID_LPUDepartment, d.code,d.indefiniteMain
*/

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#errors departmentt',@rc, null)


-- собираем ошибки неактивным сетям
insert #errors (ID_LPULetter,ImportType, IsAdvance, ChangeDate, AttachDate, DetachDate, ID_LPUAccessKind, 
	ID_Contract, ID_ContractPolicy, ID_ContractProgram, ID_ContractProgramElement, 
	ID_RetailContract, ID_RetailContractProgram, ID_RetailProgramElement, 
	ID_PriceListItem, ID_LPU, ID_LPUNet, ErrorCode, ErrorText,IsNightly)
select l.id, ImportType, IsAdvance, CD, AttachDate, DetachDate,  l.ID_LPUAccessKind,
		cp.ID_Contract,  case l.isretail when 0 then l.ID_ContractPolicy end ID_ContractPolicy, case l.isretail when 0 then ID_ContractProgram end ID_ContractProgram , 
		case l.isretail when 0 then ID_ContractProgramElement end ID_ContractProgramElement, 
		rp.ID_RetailContract, case l.isretail when 1 then ID_ContractProgram end ID_RetailContractProgram, 
							case l.isretail when 1 then ID_ContractProgramElement end ID_RetailContractProgramElement, 
		ID_PriceListItem, dbo.NullUID(ID_LPU), l.ID_LPUNet, 16 ErrorCode, 'Неактивная сеть ЛПУ ' + substring(n.FullName,1,12) ErrorText,0
from #Letters l
join LPUnet n on l.ID_LPUNet=n.id and n.IsInactive > 0
left join (select ID_ContractPolicy, ID_LPU, ID_LPUContract, ID_LPUDeptSend, ID_LPUNet, ID_Contract, ID_ContractProgram, ID_ContractProgramElement, ID_PriceListItem,
			ID_LPUAccessKind, IsPrepaid, StartDate, enddate, ksStart, ksEnd, fhiStart, fhiEnd, fhpStatus, FranchiseInterest, DeptCode
		from #pe group by ID_ContractPolicy, ID_LPU, ID_LPUContract, ID_LPUDeptSend, ID_LPUNet, ID_Contract, ID_ContractProgram, ID_ContractProgramElement, ID_PriceListItem,
						ID_LPUAccessKind, IsPrepaid, StartDate, enddate, ksStart, ksEnd, fhiStart, fhiEnd, fhpStatus, FranchiseInterest, DeptCode
	) pe on pe.ID_ContractPolicy=l.ID_ContractPolicy and pe.ksStart=l.AttachDate and pe.ID_LPUDeptSend=l.ID_LPUDepartment and pe.id_lpunet=l.ID_LPUNet and l.ID_SubjectLPU=pe.ID_LPU
			and pe.IsPrepaid=l.IsAdvance and pe.ID_LPUAccessKind = l.ID_LPUAccessKind
				and case importtype when 1 then DetachDate else AttachDate end between pe.ksStart and pe.ksEnd --and p1.StartDate between pp.ksStart and pp.ksEnd
				and not (case importtype when 1 then DetachDate else AttachDate end  between pe.startDate and pe.endDate and FranchiseInterest!=0 and not (case importtype when 1 then DetachDate else AttachDate end  between pe.fhiStart and pe.fhiEnd and fhpStatus=1)) 
				and not (case importtype when 1 then DetachDate else AttachDate end  between pe.fhiStart and pe.fhiEnd and fhpStatus != 1 and FranchiseInterest!=0) 
				and ((FranchiseInterest=0) or (FranchiseInterest!=0 and fhpStatus=1))
left join ContractPolicy cp on cp.ID = l.ID_ContractPolicy
left join RetailContractPolicy rp on rp.ID = l.ID_ContractPolicy
where l.Tp!='' 
/*group by l.id, l.id_letter, ImportType, IsAdvance, IsNightly, CD, AttachDate, DetachDate,  l.ID_LPUAccessKind,
	cp.ID_Contract,  case l.isretail when 0 then l.ID_ContractPolicy end, rp.ID_RetailContract, 
		ID_PriceListItem, ID_LPU, l.ID_LPUNet
*/
set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#errors departmentt',@rc, null)

create clustered index tErrorsIdx on #errors (ID_LPU,ID_LPUNet,ID_LPUDepartment,ID_PriceListItem,ID_Contract,ID_ContractPolicy,
										ID_ContractProgram,ID_ContractProgramElement,ID_RetailContract,ID_RetailContractProgram,ID_RetailProgramElement,ImportType)

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#errors index',null, null)

if @ID_NightSession is not null
begin
	update e set IsNightly = isnull(isnull(n.IsNightLetter,l.IsNightLetter),1)
	from #errors e
	left join LPUNet n on n.id=e.ID_LPUNet
	left join SubjectLPU l on l.id=e.ID_LPU
	
	update e set ID_Responsible = respU.ID_Responsible 
	from #errors e
	cross apply (select top 1 * from LPULetterResponsibleUser r where r.ID_LPUNet=e.ID_LPUNet or r.ID_SubjectLPU=e.ID_LPU) respU
end
/*
select * from #errors where  ID_ContractPolicy='2257B9A2-1E20-4AD1-88CC-890650536E94' and ID_LPUDepartment='3462F6D7-5806-4F8A-AC88-0F64F6E9EC5B'
select * from #Letters where  ID_ContractPolicy='2257B9A2-1E20-4AD1-88CC-890650536E94' and ID_LPUDepartment='3462F6D7-5806-4F8A-AC88-0F64F6E9EC5B'
select * from #pea where  ID_ContractPolicy='2257B9A2-1E20-4AD1-88CC-890650536E94' and ID_LPUDeptSend='3462F6D7-5806-4F8A-AC88-0F64F6E9EC5B'
*/

--if isnull(@deletePrevLetters,2) >= 2
begin
	delete l --select ErrorCode ec, ErrorText et, ldcode, * 
	from #Letters l
	join (
		select errorcode, errortext,ID_LPULetter,ID_RetailContract,ID_ContractPolicy, id_LPU, ID_LPUNet, ID_Contract, ID_PriceListItem from #errors err 
		-- TODO: Убрать комментарий ниже для генерации писем в ЛПУ с неполным набором договоров
--		where not exists(select 1 from #plishort pe where pe.ID_LPUNet = err.ID_LPUNet and pe.ErrorCode is null and pe.ID_PriceListItem=err.ID_PriceListItem and pe.ID_Contract in (err.ID_Contract,err.ID_RetailContract))
		) err on err.ID_LPULetter=l.ID 
	left join RetailContractPolicy rp on rp.ID_RetailContract=err.ID_RetailContract
	where (l.ID_ContractPolicy=err.ID_ContractPolicy or l.ID_ContractPolicy = rp.id)
    --order by ldcode, et
	-- открепы с выбранным ранеее "много договором" не будут иметь ссылки из #errors, но очистка контракта на них всё равно распостаранится, поэтому их удаляем по признаку отсутствия дог.ЛПУ
	delete #Letters where ID_LPUContract=dbo.EmptyUID(null) and ID_SubjectLPU != dbo.EmptyUID(null)
end


-------------------------------------------------------------------
-- Формируем головы новых писем
-------------------------------------------------------------------
update l set isks=1 from #Letters l
join ContractPolicy cp on cp.id=l.ID_ContractPolicy
join Contract ct on ct.id=cp.ID_Contract
join SystemLookup cType on cType.ID_SystemLookupType='8845E0FD-E44B-45BD-ADC4-21D976B52A13' and cType.id = ct.ID_ContractTypeBySourceCompany and cType.Name != 'РГС'
where l.tp!='' and l.IsRetail=0

if @ID_NightSession is not null
	update e set ID_Responsible = respU.ID_Responsible, 
				ID_Signing = respu.ID_Signing 
	from #Letters e
	cross apply (select top 1 * from LPULetterResponsibleUser r where r.ID_LPUNet=e.ID_LPUNet or r.ID_SubjectLPU=e.ID_SubjectLPU) respU


--declare @deletePrevLetters tinyint = 0
--declare @date datetime = '20230808'
if object_id('tempdb.dbo.#lh')!=0 
	drop table #lh

select NEWID() lid, @date sd, ID_SubjectLPU lpu, ID_LPUNet net, ID_LPUDepartment dept, ID_LPUContract ct, ID_LPUAccessKind ak, isKS K, nlt.ImportType it, nlt.IsAdvance isa, 0 IsNightly, 
	ID_Responsible resp, ID_Signing signing, convert(varchar(max),'') CN, convert(varchar(max),'') IM 
into #lh
from #Letters nlt
where nlt.tp!='' 
group by ID_SubjectLPU, ID_LPUNet, ID_LPUDepartment, ID_LPUContract, ID_LPUAccessKind, ImportType, IsAdvance, isKS, ID_Responsible, ID_Signing

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '#lh retail',@rc, null)

if @ID_NightSession is not null
	update e set IsNightly = isnull(isnull(n.IsNightLetter,l.IsNightLetter),1) from #lh e
	left join LPUNet n on n.id=e.net
	left join SubjectLPU l on l.id=e.lpu

--select * from #lh
--select * from #letters order by ldcode, tp, cd

update l set ID_Letter=lid from #Letters l
join #lh li on ID_LPUNet = net and ID_SubjectLPU = lpu and ID_LPUDepartment = dept and ID_LPUContract = ct and ImportType = it and IsAdvance = isa and ID_LPUAccessKind = ak 
				and tp>'' and k=isKS and resp=ID_Responsible and signing=ID_Signing

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, 'New letter component total',@rc, null)

update lh set CN = stuff((select distinct '; '+ c.ContractNumber from #Letters l, Contract c, ContractPolicy p 
				where p.ID=l.ID_ContractPolicy and c.id=p.ID_Contract and lid = l.ID_Letter and l.Tp!='' and l.IsRetail = 0
				group by c.ContractNumber order by '; '+ c.ContractNumber 
				for xml path(''),type).value('.', 'nvarchar(max)'),1,2,'') ,
			IM = stuff((select distinct '; '+ isnull(sbu.ShortName, sbp.FullName) from #Letters l 
				join ContractPolicy p on p.id=l.ID_ContractPolicy
				join Contract c on c.id=p.ID_Contract
				left join SubjectU sbU on sbU.id=c.ID_SubjectInsurant		
				left join Subject sbP on sbP.id=c.ID_SubjectInsurant
				where lid = l.ID_Letter and l.Tp!=''
				order by '; '+ isnull(sbu.ShortName, sbp.FullName) for xml path(''),type).value('.', 'nvarchar(max)'),1,2,'') 
from #lh lh where exists(select 1 from #Letters l where l.ID_Letter=lh.lid and IsRetail = 0)

update lh set CN = case CN when '' then '' else '; +' end + (select convert(varchar,count(distinct contractnumber)) + ' коробочных договоров' 
				from #Letters l, RetailContract c, RetailContractPolicy p 
				where p.ID=l.ID_ContractPolicy and c.id=p.ID_RetailContract and lh.lid = l.ID_Letter and l.Tp!='' and l.IsRetail = 1),
			IM = case IM when '' then '' else '; +' end + (select convert(varchar,count(distinct c.ID_SubjectInsurant)) + ' страхователей из коробочных договоров' 
				from #Letters l, RetailContract c, RetailContractPolicy p
				where p.ID=l.ID_ContractPolicy and c.id=p.ID_RetailContract and lh.lid = l.ID_Letter and l.Tp!='' and l.IsRetail = 1)
from #lh lh where exists(select 1 from #Letters l where l.ID_Letter=lh.lid and IsRetail = 1)

				
print convert(varchar,getdate(),108) + '	Сформировали головы новых писем'

-- заполняем letterType для новых писем -->
update l set letterType=sign(isnull(@IsNotDuplicate,0))*16+(isnull(@GenCurrentState,0)&1)*8+h.IsNightly 
from #Letters l
join #lh h on l.ID_Letter=lid

if @IsNotDuplicate = 1	-- при этом не надо на второй повтор повторять письма по набежавшим измененеиям (набежавшие после послдней нормальной генрации открепы/замены)
begin
	update l set letterType &= (255-16)	-- снимаем флажок копии на последнем письме в цепочке. Т.е. при повторе повтора перегенириться только оно
	from #Letters l
	join (select lpuHash, ID_LPUContract, max(tp) tp from #Letters lp where tp!='' group by lpuHash, ID_LPUContract having count(*)>1) lm on lm.lpuHash=l.lpuHash and lm.ID_LPUContract=l.ID_LPUContract and lm.tp=l.tp
	where l.tp!='' 						--^^^ можно поставить min(tp)+1, тогда будет повторяться вся цепочка
	-- первое в цепочке (коию старого) удаляем
	delete l
	from #Letters l
	join (select lpuHash, ID_LPUContract, min(tp) tp from #Letters lp where tp!='' group by lpuHash, ID_LPUContract having count(*)>1) lm on lm.lpuHash=l.lpuHash and lm.ID_LPUContract=l.ID_LPUContract and lm.tp=l.tp
	where l.tp!='' 
	-- опустевшие головы удаляем
	delete #lh where not exists(select 1 from #letters where ID_Letter=lid)
end
-- заполняем letterType для новых писем <--
--
/*
select errorcode, ErrorText,* from #errors
select * from #Letters
--*/

--declare @number int, @liter varchar(2)

declare @letnumtab table (respId uniqueidentifier, liter varchar(2), number int)

insert @letnumtab (respid, liter, number)
select resp, liter, isnull((select max(l.number) from LPULetter l, users u where u.id=l.ID_Responsible and u.LPULetterLiter = liter),1)
from (select resp, isnull((select LPULetterLiter from users where id=resp),'') liter from #lh group by resp) lit

--if @deletePrevLetters <= 2
begin
	-- нумерация писем
	--set @liter = isnull((select LPULetterLiter from users where id=@ID_Responsible),'')
	--set @number = isnull((select max(l.number) from LPULetter l, users u where u.id=l.ID_Responsible and u.LPULetterLiter = @liter),1)

	set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, 'start result flushing',null, null)

	begin tran

	-- 20231215 Если была замена договоров и письма сформированы, то заменённый догоовр протягиваем по остальному ключу в существующие письма
	update lu set ID_LPUContract = dbo.nullUID(lc.peaContr), letterType |= 32 
	--select lu.*, lc.peaContr, lu.ID_LPUNet,dbo.NullUID(l.ID_LPUNet),*
	from #lChgContr lc, #Letters l, LPULetterFlow lu
	where l.lpuHash = lc.lpuHash and l.ID_LPUContract=lc.peaContr and l.tp>'' 
		and lu.ID_ContractPolicy=l.ID_ContractPolicy and lu.ID_LPUContract = dbo.NullUID(lc.oldContr)
		and (lu.ID_LPUNet = dbo.NullUID(l.ID_LPUNet) or (lu.ID_SubjectLPU = dbo.NullUID(l.ID_SubjectLPU)
		and lu.ID_LPUDepartment = dbo.NullUID(l.ID_LPUDepartment)))and lu.IsAdvance = l.IsAdvance


	-- Пишем головы новых писем
	insert LPULetter (ID,State,Number,Date,CreateDate,AccountDate,PrintDate,TransmissionDate,TransmissionMethod,
		DispatchDate,DispatchMethod,ReceiptDate,ID_SubjectLPU,ID_LPUContract,FaxBranch,
		AddressBranch,ID_Responsible,ID_Signing,
		ReceiptFIO,ReceiptPost,ID_LPUDepartment,
		ImportType,IsAdvance,ID_LPUAccessKind,Prefix,
		ID_Branch,ContractNumbers,Insurers,
		ID_LPUNet,IsNightly,Postfix,ID_Session,ID_NightServiceSession)
	/*
	declare @date datetime='20230806', @letterdate datetime='20230806', @id_session as uniqueidentifier = newid(), 
		@ID_Signing as uniqueidentifier = newid(), @ID_Responsible as uniqueidentifier = newid(), @ID_Branch uniqueidentifier = '31DE0CD4-E579-44A6-B37B-D0E301B14F42', @ID_NightSession uniqueidentifier,
		@number int, @liter varchar(2); set @liter = isnull((select LPULetterLiter from users where id=@ID_Responsible),''); set @number = isnull((select max(l.number) from dbo.LPULetter l, users u where u.id=l.ID_Responsible and u.LPULetterLiter = @liter),1)--*/
	select lID, sign(li.IsNightly) State, ROW_NUMBER() over (partition by resp order by lpu, net)+Number Number, @LetterDate Date, getdate() CreateDate, 
		case li.IsNightly when 0 then null else getdate() end AccountDate, null PrintDate, null TransmissionDate, null TransmissionMethod,
		null DispatchDate,null DispatchMethod, null ReceiptDate,
		dbo.NullUID(lpu) ID_SubjectLPU, case li.it when 4 then null else dbo.NullUID(li.ct) end ID_Contract, null FaxBranch, addressname AddressBranch,
		isnull(li.resp,@ID_Responsible) ID_Responsible, isnull(li.signing,@ID_Signing), 
		case li.IsNightly when 0 then null else 'авт. сервис' end ReceiptFIO, null ReceiptPost, dbo.NullUID(dept) ID_LPUDepartment,
		it ImportType, li.isa IsAdvance, case li.it when 4 then null else ak end ID_LPUAccessKind, isnull(LPULetterPrefix,'')+isnull(reg.code,'')+liter Prefix, 
		--case k when 0 then dbo.EmptyUID(brch.ID_Branch) else '31DE0CD4-E579-44A6-B37B-D0E301B14F42' end ID_Branch, 
		@ID_Branch ID_Branch, CN ContractNumbers, IM Insurers,
		dbo.NullUID(Net) ID_LPUNet, IsNightly, case k when 1 then 'КС' end Postfix,
		@ID_Session, @ID_NightSession --@session ID_NightServiceSession, isnull(isErr,0)
	from #lh li
	join @letnumtab litnum on litnum.respId=resp 
	-- left join (select 1 isErr, ID_LpuLetter from #errors group by ID_LpuLetter) err on err.ID_LPULetter=lid
	outer apply (select top 1 substring(addressname,1,200) addressname from SubjectAddress addr where addr.ID_Object=li.dept and AddressType=4 and li.dept!=dbo.EmptyUID(null) and li.dept is not null) addr
	outer apply (select top 1 LPULetterPrefix from Insurers where Insurers.ID_Branch = @ID_Branch order by LPULetterPrefix desc) insur
	outer apply (select top 1 convert(varchar, Code)code from Regions where Regions.id_branch=@ID_Branch ) reg


	set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, 'LPULetter',@rc, null)
	print convert(varchar,getdate(),108) + '	Залили головы новых писем'

	insert LPULetterNetContract (ID, ID_LPULetter, ID_SubjectLPU, ID_LPUContract)
	select newid(), lh.lid, pli.ID_LPU, dbo.EmptyUID(pli.ID_LPUContract) from #plishort pli, #lh lh 
	where  pli.ID_LPUNet = lh.net and ID_LPUContract is not null
	group by lh.lid, pli.ID_LPU, pli.ID_LPUContract order by lid

	set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, 'LPULetterNetContract',@rc, null)

	if @ID_Branch != '31DE0CD4-E579-44A6-B37B-D0E301B14F42'
		insert ObjectRegions (ID_Object, ID_Region)
		select lh.lid, r.ID from #lh lh, Regions r where r.ID_Branch = @ID_Branch
	
	insert ObjectRegions (ID_Object, ID_Region)
	select lh.lid, r.ID from #lh lh, Regions r where r.ID_Branch = '31DE0CD4-E579-44A6-B37B-D0E301B14F42'
	

	--select * from  #Letters li where ID_Letter is not null 
	--select * from #cpp

	insert LPULetterComponent( ID,ID_LPULetter,ID_SubjectP,ID_ContractPolicy,ID_ContractProgram,ID_ContractProgramOld,
								ChangeDate,CheckState, ID_Contract,ProgramNumberNew,IsAdvanceProgramNew,ProgramNumberOld,
								IsAdvanceProgramOld,ParentFIO,Gender,ErrorMessage,
								ServiceTypesNew,ServiceTypesOld,
								ServiceTypeCodeNew,ServiceTypeCodeOld,
								PreAdvanceNumber,PreAdvanceNumberOld,
								ID_RetailContract,ID_RetailContractPolicy,
								FullNameSend,BirthDaySend,ID_ParentLPULetterComponent,
								AttachDate,DetachDate)
	select li.ID,ID_Letter ID_LPULetter,ID_SubjectP, li.ID_ContractPolicy, null ID_ContractProgram, null ID_ContractProgramOld,
		case importtype when 1 then li.detachdate+1 when 4 then @date else li.AttachDate end ChangeDate, 2*sign(lh.IsNightly) CheckState,   -- над последним ещё подумать
		ID_Contract,
		null ProgramNumberNew, null IsAdvanceProgramNew, null ProgramNumberOld, null IsAdvanceProgramOld, 
		spar.FullName ParentFIO, sp.Gender, null ErrorMessage,
		newaid  ServiceTypesNew,	oldAid ServiceTypesOld, 
		newfact ServiceTypeCodeNew,	oldFact ServiceTypeCodeOld,
		newadv PreAdvanceNumber,	oldAdv PreAdvanceNumberOld,
		null ID_RetailContract,		null ID_RetailContractPolicy,
		sp.FullName	FullNameSend,	sp.BirthDay BirthDaySend, 
		null ID_ParentLPULetterComponent,   -- с этим разобраться при формировании писем на изменение данных
		case li.ImportType when 4 then null else li.AttachDate end,	case li.ImportType when 4 then null else li.detachdate end
		--,		isnull(isErr,0)
	from #Letters li
	join #lh lh on lh.lid=li.ID_Letter
	--left join (select 1 isErr, ID_LpuLetter, ID_ContractPolicy from #errors group by ID_LpuLetter, ID_ContractPolicy) err on err.ID_LPULetter=li.ID_Letter and li.ID_ContractPolicy=err.ID_ContractPolicy
	join ContractPolicy cp on li.ID_ContractPolicy=cp.id
	join Contract c on c.id=cp.ID_Contract
	join subjectp sp on sp.id=cp.ID_SubjectP
	left join subjectp spar on spar.id=sp.ID_Parent
	where li.ID_Letter is not null and isretail=0
	order by ID_LPULetter

	set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, 'LPULetterComponent',@rc, null)
	print convert(varchar,getdate(),108) + '	Залили строки новых писем ДМС:	' + convert(varchar,@@rowcount)

	insert LPULetterComponent( ID,ID_LPULetter,ID_SubjectP,ID_ContractPolicy,ID_ContractProgram,ID_ContractProgramOld,
								ChangeDate,CheckState, ID_Contract,ProgramNumberNew,IsAdvanceProgramNew,ProgramNumberOld,
								IsAdvanceProgramOld,ParentFIO,Gender,ErrorMessage,
								ServiceTypesNew,ServiceTypesOld,
								ServiceTypeCodeNew,ServiceTypeCodeOld,
								PreAdvanceNumber,PreAdvanceNumberOld,
								ID_RetailContract,ID_RetailContractPolicy,
								FullNameSend,BirthDaySend,ID_ParentLPULetterComponent,AttachDate,DetachDate)
	select li.ID,ID_Letter ID_LPULetter,ID_SubjectP, null ID_ContractPolicy, null ID_ContractProgram, null ID_ContractProgramOld,
		case Importtype when 1 then li.detachdate+1 when 4 then @date else li.AttachDate end ChangeDate, 2*sign(lh.IsNightly) CheckState,   -- над последним ещё подумать
		null ID_Contract,
		null ProgramNumberNew, null IsAdvanceProgramNew, null ProgramNumberOld, null IsAdvanceProgramOld, 
		spar.FullName ParentFIO, sp.Gender, null ErrorMessage,
		newAid  ServiceTypesNew,	oldAid ServiceTypesOld, 
		newFact ServiceTypeCodeNew,	oldFact ServiceTypeCodeOld,
		newAdv PreAdvanceNumber,	oldAdv PreAdvanceNumberOld,
		rc.id ID_RetailContract,	rp.id ID_RetailContractPolicy,
		sp.FullName	FullNameSend,	sp.BirthDay BirthDaySend, 
		null ID_ParentLPULetterComponent,   -- с этим разобраться при формировании писем на изменение данных
		case li.ImportType when 4 then null else li.AttachDate end,	case li.ImportType when 4 then null else li.detachdate end
		--,isnull(isErr,0)
	from #Letters li
	join #lh lh on lh.lid=li.ID_Letter
	--left join (select 1 isErr, ID_LpuLetter, ID_ContractPolicy from #errors group by ID_LpuLetter, ID_ContractPolicy) err on err.ID_LPULetter=li.ID_Letter and li.ID_ContractPolicy=err.ID_ContractPolicy
	join RetailContractPolicy rp on rp.id = li.ID_ContractPolicy
	join RetailContract rc on rc.ID = rp.ID_RetailContract
	join subjectp sp on sp.id=rp.ID_SubjectP
	left join subjectp spar on spar.id=sp.ID_Parent
	where li.ID_Letter is not null and li.isretail=1 
	order by li.id_letter

	set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, 'LPULetterComponent retail',@rc, null)

	print convert(varchar,getdate(),108) + '	Залили строки новых писем Коробки:	' + convert(varchar,@@rowcount)

	insert LPULetterFlow (ID, ID_SubjectLPU, ID_LPUNet, ID_LPUDepartment, Date, ImportType, ID_LPUContract, 
		ID_LPUAccessKind, IsAdvance, ID_ContractPolicy, AttachDate, DetachDate, IsRetail, LetterType,
		ID_Contract, BaseService, FactService, AdvService, FullName, ParentName, Gender, BirthDate)
	--declare @date datetime='20230808'
	select l.ID, dbo.NullUID(ID_SubjectLPU), dbo.NullUID(ID_LPUNet), dbo.NullUID(ID_LPUDepartment), @Date, ImportType, dbo.NullUID(ID_LPUContract), 
		ID_LPUAccessKind, IsAdvance, ID_ContractPolicy, AttachDate, DetachDate, IsRetail, letterType,	-- послденее - тип письма для исключения предыдущих сверок
		ID_Contract, newaid, newfact, newadv, s.FullName, ps.FullName, sp.Gender, sp.BirthDay
	from #Letters l
	--join #lh lh on lh.lid=l.ID_Letter
	join (select id, id_SubjectP, ID_Contract from ContractPolicy union all select id, id_SubjectP, ID_RetailContract from RetailContractPolicy pr) pl on pl.id=l.ID_ContractPolicy 
	join Subject s on s.id = pl.ID_SubjectP
	join SubjectP sp on sp.id = s.id
	left join Subject ps on ps.id=sp.ID_Parent
	where ID_Letter is not null and tp!=''

	set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, 'LPULetterFlow',@rc, null)

	print convert(varchar,getdate(),108) + '	Залили логи новых писем:	' + convert(varchar,@@rowcount)

	insert LPULetterInPolicy (ID,ID_ContractPolicy,ID_ContractProgramElement,ID_LPULetterComponent,ImportType,ChangeDate,ID_MedicineServiceType,
									ID_ContractProgramElementKS,ID_RetailContractPolicy,ID_RetailContractProgramElement)
	select newid(), case pe.isretail when 0 then pe.ID_ContractPolicy end ID_ContractPolicy, 
			case pe.isretail when 0 then pe.ID_ContractProgramElement end ID_ContractProgramElement, 
			l.id, l.ImportType, l.CD, pe.ID_MedicineServiceType, pe.ID_ContractProgramElementKS, 
			case l.isretail when 1 then pe.ID_ContractPolicy end ID_RetailContractPolicy, 
			case pe.isretail when 1 then pe.ID_ContractProgramElement end ID_RetailContractProgramElement
	from #Letters l 
	join (select isretail,id_contractpolicy, ID_ContractProgram, pe.id_contract, pe.id_lpucontract, pe.ID_LPU, ID_MedicineServiceType,
		id_lpudeptsend, pe.id_lpunet, pe.ksStart, pe.ksEnd, StartDate, enddate, progEnd, fhiStart, fhiEnd, FranchiseInterest, fhpStatus,
		IsPrepaid, ID_LPUAccessKind, pe.ID_PriceListItem, ID_ContractProgramElement, ID_ContractProgramElementKS
		from #pe pe 
		group by isretail,ID_ContractProgram,id_contractpolicy, pe.id_contract, pe.id_lpucontract, pe.id_lpu, id_lpudeptsend, ID_MedicineServiceType,
				pe.id_lpunet, pe.ksStart, progEnd, IsPrepaid, ID_LPUAccessKind, pe.ID_PriceListItem, ID_ContractProgramElement, 
				StartDate, enddate, fhiStart, fhiEnd, pe.ksend, FranchiseInterest, fhpStatus, ID_ContractProgramElementKS
	) pe on pe.ID_ContractPolicy=l.ID_ContractPolicy 
		and ((pe.ID_LPUDeptSend=l.ID_LPUDepartment and l.id_subjectlpu=pe.id_lpu) or (pe.id_lpunet=l.ID_LPUNet and pe.id_lpunet!=dbo.EmptyUID(null)) and l.ID_LPUNet!=dbo.EmptyUID(null))
		and pe.IsPrepaid=l.IsAdvance and pe.ID_LPUAccessKind = l.ID_LPUAccessKind and pe.id_lpucontract=l.ID_LPUContract
				and case importtype when 1 then DetachDate else AttachDate end between pe.ksStart and pe.ksEnd --and p1.StartDate between pp.ksStart and pp.ksEnd
				and not (case importtype when 1 then DetachDate else AttachDate end  between pe.startDate and pe.endDate and FranchiseInterest!=0 and not (case importtype when 1 then DetachDate else AttachDate end  between pe.fhiStart and pe.fhiEnd and fhpStatus=1)) 
				and not (case importtype when 1 then DetachDate else AttachDate end  between pe.fhiStart and pe.fhiEnd and fhpStatus != 1 and FranchiseInterest!=0) 
				and ((FranchiseInterest=0) or (FranchiseInterest!=0 and fhpStatus=1))
	where l.tp!='' 

	set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, 'LPULetterInPolicy',@rc, null)

	declare @LetterCount_2 int = 0
	set @LetterCount = 0
	set @ErrorCount = 0

	select @LetterCount=count(*), @LetterCount_2 = isnull(sum(case IsNightly when 2 then 1 else 0 end),0) from #lh
	select @ErrorCount=count(*) from #errors


	update ns set ContractCount					= contrCnt,			-- количество обработанных договоров ДМС 
				ContractPolicyCount				= polCnt,			-- количество обработанных полисов ДМС
				ContractPolicyProgramCount		= progCnt,			-- количество обработанных программ в полисах ДМС
				RetailContractCount				= rcontrCnt,		-- количество обработанных коробочных договоров
				RetailContractPolicyCount		= rpolCnt,			-- количество обработанных коробочных полисов
				RetailContractPolicyProgramCount= rprogCnt,			-- количество обработанных программ в коробочных полисах 
				ChangeItemSubjectPCount			= chgCnt,			-- количество обработанных измененных физ лиц
				ChangeItemCount					= chgCnt,			-- количество обработанных строк строк писем с измененными ФЛ
				ErrorCount						= @ErrorCount,		-- количество строк ошибок сгенерированных в ночном запуске
				LetterCount						= @LetterCount,		-- количество шапок писем сгененрированных в ночном запуске
				LetterNoSendCount				= @LetterCount_2	-- количество шапок отложенных писем сгененрированных в ночном запуске
	from NightServiceSession ns, 
		(select count(distinct case p.isretail when 0 then ID_Contract end) contrCnt, count(distinct case p.isretail when 0 then ID_ContractPolicy end) polCnt, 
				count(distinct case p.isretail when 0 then ID_ContractProgram end) progCnt, count(distinct case p.isretail when 1 then ID_Contract end) rcontrCnt, 
				count(distinct case p.isretail when 1 then ID_ContractPolicy end) rpolCnt, count(distinct case p.isretail when 1 then ID_ContractProgram end) rprogCnt
		from #pe p) p,
		(select count(*) chgCnt from #Letters where ImportType=4 and tp!='') l
	where ns.id = @ID_NightSession


	update fe set OccuredLastTime = getdate(), LPUWrongIDs=e.LPUWrongIDs, ErrorText = e.ErrorText, isNightly = e.isNightly,
		IsAdvance = e.IsAdvance, ID_Responsible = isnull(e.ID_Responsible, @ID_Responsible), ErrorCounter = isnull(ErrorCounter,1) + 1,
		ChangeDate = e.ChangeDate, AttachDate = e.AttachDate, DetachDate = e.DetachDate, 
		usageCounter = 0, ID_LPUContract = null, -- если ошибка возникла повторно (контракт ЛПУ просрали), то сбрасываем коррецию
		ID_SessionLast = @ID_Session
	--select *
	from #errors e, LPULetterErrors fe
	where e.ImportType = fe.ImportType and
		(e.ID_LPU = 						fe.ID_LPU						or (e.ID_LPU is null and 						fe.ID_LPU						is null)) and 
		(e.ID_LPUNet = 						fe.ID_LPUNet					or (e.ID_LPUNet is null and 					fe.ID_LPUNet					is null)) and 
		(e.ID_LPUDepartment = 				fe.ID_LPUDepartment				or (e.ID_LPUDepartment is null and 				fe.ID_LPUDepartment				is null)) and 
		(e.ID_PriceListItem = 				fe.ID_PriceListItem				or (e.ID_PriceListItem is null and 				fe.ID_PriceListItem				is null)) and 
		(e.ID_Contract = 					fe.ID_Contract					or (e.ID_Contract is null and 					fe.ID_Contract					is null)) and 
		(e.ID_ContractPolicy = 				fe.ID_ContractPolicy			or (e.ID_ContractPolicy is null and 			fe.ID_ContractPolicy			is null)) and 
		(e.ID_ContractProgram = 			fe.ID_ContractProgram			or (e.ID_ContractProgram is null and 			fe.ID_ContractProgram			is null)) and 
		(e.ID_ContractProgramElement = 		fe.ID_ContractProgramElement	or (e.ID_ContractProgramElement is null and 	fe.ID_ContractProgramElement	is null)) and 
		(e.ID_RetailContract = 				fe.ID_RetailContract			or (e.ID_RetailContract is null and 			fe.ID_RetailContract			is null)) and 
		(e.ID_RetailContractProgram = 		fe.ID_RetailContractProgram		or (e.ID_RetailContractProgram is null and 		fe.ID_RetailContractProgram		is null)) and 
		(e.ID_RetailProgramElement = 		fe.ID_RetailProgramElement		or (e.ID_RetailProgramElement is null and 		fe.ID_RetailProgramElement		is null))
	
	set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, 'LPULetterErrors update',@rc, null)

	delete e --select *
	from #errors e, LPULetterErrors fe
	where e.ImportType = fe.ImportType and
		(e.ID_LPU = 						fe.ID_LPU						or (e.ID_LPU is null and 						fe.ID_LPU						is null)) and 
		(e.ID_LPUNet = 						fe.ID_LPUNet					or (e.ID_LPUNet is null and 					fe.ID_LPUNet					is null)) and 
		(e.ID_LPUDepartment = 				fe.ID_LPUDepartment				or (e.ID_LPUDepartment is null and 				fe.ID_LPUDepartment				is null)) and 
		(e.ID_PriceListItem = 				fe.ID_PriceListItem				or (e.ID_PriceListItem is null and 				fe.ID_PriceListItem				is null)) and 
		(e.ID_Contract = 					fe.ID_Contract					or (e.ID_Contract is null and 					fe.ID_Contract					is null)) and 
		(e.ID_ContractPolicy = 				fe.ID_ContractPolicy			or (e.ID_ContractPolicy is null and 			fe.ID_ContractPolicy			is null)) and 
		(e.ID_ContractProgram = 			fe.ID_ContractProgram			or (e.ID_ContractProgram is null and 			fe.ID_ContractProgram			is null)) and 
		(e.ID_ContractProgramElement = 		fe.ID_ContractProgramElement	or (e.ID_ContractProgramElement is null and 	fe.ID_ContractProgramElement	is null)) and 
		(e.ID_RetailContract = 				fe.ID_RetailContract			or (e.ID_RetailContract is null and 			fe.ID_RetailContract			is null)) and 
		(e.ID_RetailContractProgram = 		fe.ID_RetailContractProgram		or (e.ID_RetailContractProgram is null and 		fe.ID_RetailContractProgram		is null)) and 
		(e.ID_RetailProgramElement = 		fe.ID_RetailProgramElement		or (e.ID_RetailProgramElement is null and 		fe.ID_RetailProgramElement		is null))

	set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, '@errors delete',@rc, null)
	
	insert LPULetterErrors (ImportType, ID_LPU, ID_LPUNet, ID_LPUDepartment, ID_PriceListItem, ID_Contract, ID_ContractPolicy, 
		ID_ContractProgram,ID_ContractProgramElement, ID_RetailContract, 
		ID_RetailContractProgram, ID_RetailProgramElement, IsAdvance, 
		ID_LPUAccessKind, ChangeDate, AttachDate, DetachDate, 
		IsNightly, ID_Responsible, ErrorCode, LPUWrongIDs, ErrorText,
		ID_SessionLast, ID_SessionFirst)
	select ImportType, dbo.NullUID(ID_LPU), dbo.NullUID(ID_LPUNet), dbo.NullUID(ID_LPUDepartment), case importtype when 4 then null else ID_PriceListItem end, ID_Contract, ID_ContractPolicy, 
		case importtype when 4 then null else ID_ContractProgram end, case importtype when 4 then null else ID_ContractProgramElement end, ID_RetailContract, 
		case importtype when 4 then null else ID_RetailContractProgram end, case importtype when 4 then null else ID_RetailProgramElement end, IsAdvance, 
		case importtype when 4 then null else ID_LPUAccessKind end, ChangeDate, case importtype when 4 then null else AttachDate end, case importtype when 4 then null else DetachDate end, 
		IsNightly, isnull(ID_Responsible, @ID_Responsible), ErrorCode, max(LPUWrongIDs), max(ErrorText), 
		@ID_Session, @ID_Session
	from #errors
	group by ImportType, dbo.NullUID(ID_LPU), dbo.NullUID(ID_LPUNet), dbo.NullUID(ID_LPUDepartment), case importtype when 4 then null else ID_PriceListItem end, ID_Contract, ID_ContractPolicy, 
		case importtype when 4 then null else ID_ContractProgram end, case importtype when 4 then null else ID_ContractProgramElement end, ID_RetailContract, ID_Responsible,
		case importtype when 4 then null else ID_RetailContractProgram end, case importtype when 4 then null else ID_RetailProgramElement end, IsAdvance, errorcode, IsNightly,
		case importtype when 4 then null else ID_LPUAccessKind end, ChangeDate, case importtype when 4 then null else AttachDate end, case importtype when 4 then null else DetachDate end

	set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, 'LPULetterErrors insert',@rc, null)

	/* Т.к. от массовых исправлений отказались, то пока баним использование этой таблички
	update c set usageCounter = usageCounter + 1, lastUsedTime = getdate() 
	from dbo.LPULetterErrorCorrections c, (select ID_Correction from #pe where ID_Correction is not null group by ID_Correction) pe 
	where pe.ID_Correction = c.id
	*/
	-- а тут проставляем usageCounter в ошибках, чтобы вызывающие коллеги знали, о том, что ошибку исправили и применили в перепрогоне

	update c set usageCounter = usageCounter + 1
	from LPULetterErrors c, #pe pe 
	where pe.ID_LPUErrCorr = c.id

	update c set usageCounter = usageCounter + 1
	from LPULetterErrors c, #plishort pe 
	where pe.ID_LPUErrCorr = c.id
	
	set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, 'LetterErrors сorrections update',@rc, null)

	print convert(varchar,getdate(),108) + '	Залили ошибки'

	commit tran 
	--rollback tran
end


if (select count(distinct id_contractpolicy) from #pea p)<5 and @@servername='FIREBIRD\DMS' and @deletePrevLetters is not null
begin
	declare @sDebugRun varchar(1000) --, @date datetime = '20230808', @deletePrevLetters int = 1
	Set @sDebugRun = 'exec tmp.prepareLPULetterDebugInfo '''+ convert(varchar,@date,23) + ' ' + convert(varchar,getdate(),108) + ''','+convert(varchar,@deletePrevLetters)
--	print @sDebugRun 
	if object_id('tmp.prepareLPULetterDebugInfo') is not null 
	begin
		exec(@sDebugRun)
		set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, 'prepareLPULetterDebugInfo',null, @sDebugRun)
	end
	if object_id('tmp.prepareLPUContractPolicyDiagram') is not null 
	begin
		select top 1 @sDebugRun = 'exec tmp.prepareLPUContractPolicyDiagram '''+c.ContractNumber+''','''++ convert(varchar,@date,23) + ' ' + convert(varchar,getdate(),108) + '''' from #pe p, Contract c where c.id=p.ID_Contract
		exec(@sDebugRun)
		set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, 'prepareLPUContractPolicyDiagram', null, @sDebugRun)
	end


end


print convert(varchar,getdate(),108) + '	Конец'

update LPULetterSession set duration = datediff(second,starttime,getdate()), LettersGenerated = @LetterCount, 
								LetterErrors = @ErrorCount,	LettersLinesGenerated = (select count(*) from #Letters)
where id=@ID_Session

set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, 'prepareLPULettersByDate: success', null, null)


return 
end try
begin catch
	declare @msg varchar(4000)  = ERROR_MESSAGE()
	if @@TRANCOUNT>0 rollback tran
	update LPULetterSession set duration = datediff(second,starttime,getdate()), errMsg = @msg where id=@ID_Session
	set @rc=@@rowcount if @deletePrevLetters is not null and @id_session is not null insert LPULetterSessionTraceDetail (ID_Session, logStep, logData, logText) values(@ID_Session, 'prepareLPULettersByDate: fault', null, @msg)
	raiserror(@msg,16,16)
end catch
return 

/*
select l.*, datediff(millisecond,lt,logtime)/1000. duration, datediff(millisecond,ls,logtime)/1000. time 
from LPULetterSessionTraceDetail l
outer apply (select min(logtime) ls, max(logtime) lt from LPULetterSessionTraceDetail l2 where l2.id_session=l.id_session and l2.logtime<l.logtime) lt
where ID_Session in (select top 15 ID from dbo.LPULetterSession order by starttime desc)
union all
select * from (select top 15 0 i, id, starttime, procname, null ld, proccall,Duration,0 dt from dbo.LPULetterSession t order by starttime desc) s
order by logtime desc

*/
